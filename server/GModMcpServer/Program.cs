using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using GModMcpServer.Host;
using GModMcpServer.Host.Tools;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace GModMcpServer;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        var builder = Microsoft.Extensions.Hosting.Host.CreateApplicationBuilder(args);

        builder.Configuration
            .AddEnvironmentVariables(prefix: "MCP_")
            .AddCommandLine(args);

        // stdio transport: logs MUST go to stderr (or a file), not stdout.
        builder.Logging.ClearProviders();
        builder.Logging.AddConsole(opts => opts.LogToStandardErrorThreshold = LogLevel.Trace);
        builder.Logging.SetMinimumLevel(LogLevel.Information);

        var dataPath = ResolveDataPath(builder.Configuration);
        var mcpRoot = Path.Combine(dataPath, "mcp");
        var gameRoot = ResolveGameRoot(dataPath);
        Directory.CreateDirectory(mcpRoot);

        // Per-process session id so multiple .NET hosts sharing the same GMod
        // data dir don't read each other's request/response files.
        var sessionId = Guid.NewGuid().ToString("N");

        builder.Services.AddSingleton(new BridgePaths(mcpRoot, sessionId));
        builder.Services.AddSingleton<ManifestWatcher>(sp =>
            new ManifestWatcher(mcpRoot, sp.GetRequiredService<ILoggerFactory>().CreateLogger<ManifestWatcher>()));
        builder.Services.AddSingleton<FileBridgeRegistry>(sp =>
            new FileBridgeRegistry(mcpRoot, sessionId, sp.GetRequiredService<ILoggerFactory>()));

        builder.Services.AddSingleton<GameProcessManager>(sp =>
            new GameProcessManager(gameRoot, sp.GetRequiredService<ILoggerFactory>().CreateLogger<GameProcessManager>()));

        builder.Services.AddSingleton<McpServerAccessor>();

        builder.Services.AddSingleton<IHostTool, LaunchTool>();
        builder.Services.AddSingleton<IHostTool, CloseTool>();
        builder.Services.AddSingleton<IHostTool, StatusTool>();

        builder.Services
            .AddMcpServer()
            .WithStdioServerTransport()
            .WithListToolsHandler(ListToolsAsync)
            .WithCallToolHandler(CallToolAsync);

        builder.Services.AddHostedService<BridgeHostedService>();

        var host = builder.Build();
        await host.RunAsync().ConfigureAwait(false);
        return 0;
    }

    private static string ResolveDataPath(IConfiguration cfg)
    {
        var explicitPath = cfg["data-path"] ?? cfg["GMOD_DATA"];
        if (!string.IsNullOrEmpty(explicitPath)) return explicitPath;

        var candidates = new[]
        {
            @"C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\data",
            @"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod\data",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".steam", "steam", "steamapps", "common", "GarrysMod", "garrysmod", "data"),
        };
        foreach (var c in candidates)
        {
            if (Directory.Exists(c)) return c;
        }

        throw new InvalidOperationException(
            "Could not locate the GMod data folder. Pass --data-path <path> or set MCP_GMOD_DATA.");
    }

    /// <summary>
    /// data path = <c>...\GarrysMod\garrysmod\data</c>;
    /// game root = <c>...\GarrysMod</c> (where hl2.exe lives).
    /// </summary>
    private static string ResolveGameRoot(string dataPath)
    {
        var garrysmod = Path.GetDirectoryName(dataPath);
        var gameRoot = Path.GetDirectoryName(garrysmod);
        if (string.IsNullOrEmpty(gameRoot))
        {
            throw new InvalidOperationException($"Cannot derive game root from data path: {dataPath}");
        }
        return gameRoot;
    }

    private static ValueTask<ListToolsResult> ListToolsAsync(
        RequestContext<ListToolsRequestParams> ctx, CancellationToken ct)
    {
        var services = ctx.Services ?? throw new InvalidOperationException("RequestContext.Services is null");
        services.GetRequiredService<McpServerAccessor>().TrySet(ctx.Server);
        var watcher = services.GetRequiredService<ManifestWatcher>();
        var hostTools = services.GetServices<IHostTool>();

        var tools = new List<Tool>();

        // Host-side tools (always available).
        foreach (var ht in hostTools)
        {
            tools.Add(new Tool
            {
                Name = ht.Name,
                Description = ht.Description,
                InputSchema = ht.InputSchema,
            });
        }

        // Dynamic GMod-side tools from the merged manifest.
        var manifest = watcher.Current;
        foreach (var t in manifest.Tools.Values)
        {
            var realmHint = t.Realm == "server" ? " (server realm)" : " (client realm)";
            var desc = string.IsNullOrEmpty(t.Entry.Description)
                ? $"GMod function {t.FunctionId}{realmHint}"
                : $"{t.Entry.Description}{realmHint}";

            JsonElement inputSchema;
            if (t.Entry.Schema != null)
            {
                inputSchema = JsonSerializer.Deserialize<JsonElement>(t.Entry.Schema.ToJsonString());
            }
            else
            {
                using var doc = JsonDocument.Parse("""{"type":"object","properties":{},"required":[]}""");
                inputSchema = doc.RootElement.Clone();
            }

            tools.Add(new Tool
            {
                Name = t.McpName,
                Description = desc,
                InputSchema = inputSchema,
            });
        }

        return ValueTask.FromResult(new ListToolsResult { Tools = tools });
    }

    private static async ValueTask<CallToolResult> CallToolAsync(
        RequestContext<CallToolRequestParams> ctx, CancellationToken ct)
    {
        var name = ctx.Params?.Name ?? throw new ArgumentException("Tool name is required.");
        var services = ctx.Services ?? throw new InvalidOperationException("RequestContext.Services is null");
        services.GetRequiredService<McpServerAccessor>().TrySet(ctx.Server);

        // Host tools take precedence — they don't go through the file bridge.
        var hostTool = services.GetServices<IHostTool>().FirstOrDefault(t => t.Name == name);
        if (hostTool is not null)
        {
            try
            {
                return await hostTool.InvokeAsync(ctx.Params?.Arguments, ct).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                return ErrorResult($"host tool error: {ex.Message}");
            }
        }

        var watcher = services.GetRequiredService<ManifestWatcher>();
        var bridges = services.GetRequiredService<FileBridgeRegistry>();

        if (!watcher.Current.Tools.TryGetValue(name, out var descriptor))
        {
            return ErrorResult($"unknown tool: {name}");
        }

        var bridge = bridges.Get(descriptor.Realm);

        // Reassemble the arguments dictionary into a JSON object.
        var argsObj = new JsonObject();
        if (ctx.Params?.Arguments is { } argDict)
        {
            foreach (var kv in argDict)
            {
                argsObj[kv.Key] = JsonNode.Parse(kv.Value.GetRawText());
            }
        }
        var argsElement = JsonSerializer.Deserialize<JsonElement>(argsObj.ToJsonString());

        try
        {
            var resp = await bridge.SendAsync(descriptor.FunctionId, argsElement, TimeSpan.FromSeconds(10), ct)
                .ConfigureAwait(false);

            var resultJson = resp.Result?.ToJsonString() ?? "null";
            var ok = resp.Result is JsonObject obj
                && obj.TryGetPropertyValue("ok", out var okNode)
                && okNode is JsonValue okVal
                && okVal.TryGetValue<bool>(out var okBool)
                && okBool;

            return new CallToolResult
            {
                Content = new List<ContentBlock>
                {
                    new TextContentBlock { Text = resultJson },
                },
                IsError = !ok,
            };
        }
        catch (TaskCanceledException)
        {
            return ErrorResult("timed out waiting for GMod response (is mcp_enable 1?)");
        }
        catch (Exception ex)
        {
            return ErrorResult($"bridge error: {ex.Message}");
        }
    }

    private static CallToolResult ErrorResult(string message) => new()
    {
        IsError = true,
        Content = new List<ContentBlock> { new TextContentBlock { Text = message } },
    };
}

public sealed record BridgePaths(string McpRoot, string SessionId);

public sealed class FileBridgeRegistry : IDisposable
{
    private readonly Dictionary<string, FileBridge> _bridges;

    public FileBridgeRegistry(string mcpRoot, string sessionId, ILoggerFactory loggerFactory)
    {
        _bridges = new Dictionary<string, FileBridge>(StringComparer.Ordinal)
        {
            ["server"] = new FileBridge(mcpRoot, "server", sessionId, loggerFactory.CreateLogger("FileBridge[server]")),
            ["client"] = new FileBridge(mcpRoot, "client", sessionId, loggerFactory.CreateLogger("FileBridge[client]")),
        };
    }

    public FileBridge Get(string realm) => _bridges[realm];

    public void Dispose()
    {
        foreach (var b in _bridges.Values) b.Dispose();
    }
}

internal sealed class BridgeHostedService : BackgroundService
{
    private readonly ManifestWatcher _watcher;
    private readonly FileBridgeRegistry _bridges;
    private readonly McpServerAccessor _serverAccessor;
    private readonly ILogger<BridgeHostedService> _log;

    public BridgeHostedService(
        ManifestWatcher watcher,
        FileBridgeRegistry bridges,
        McpServerAccessor serverAccessor,
        ILogger<BridgeHostedService> log)
    {
        _watcher = watcher;
        _bridges = bridges;
        _serverAccessor = serverAccessor;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _log.LogInformation("GMod MCP bridge ready. Manifest dir watched.");

        EventHandler<MergedManifest> handler = (_, _) =>
        {
            // Captured server reference is populated lazily on the first tool call
            // (see ListToolsAsync / CallToolAsync). Before that, MCP clients still
            // fetch a fresh tools/list on connect, so missing the very first
            // manifest write is harmless.
            var server = _serverAccessor.Server;
            if (server is null) return;
            _ = Task.Run(async () =>
            {
                try
                {
                    await server.SendNotificationAsync(
                        NotificationMethods.ToolListChangedNotification,
                        stoppingToken).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    _log.LogWarning(ex, "Failed to send tools/list_changed notification");
                }
            }, stoppingToken);
        };

        _watcher.Changed += handler;
        try
        {
            await Task.Delay(Timeout.Infinite, stoppingToken).ConfigureAwait(false);
        }
        catch (TaskCanceledException) { /* shutdown */ }
        finally
        {
            _watcher.Changed -= handler;
        }
    }
}
