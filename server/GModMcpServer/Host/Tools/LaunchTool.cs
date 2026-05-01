using System.Text.Json;
using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

public sealed class LaunchTool : IHostTool
{
    private const string BootstrapMap = "gm_construct";
    private const string BootstrapGamemode = "sandbox";

    private readonly GameProcessManager _proc;
    private readonly string _mcpRoot;

    public LaunchTool(GameProcessManager proc, BridgePaths paths)
    {
        _proc = proc;
        _mcpRoot = paths.McpRoot;
    }

    public string Name => "host_launch";

    public string Description =>
        "Launch Garry's Mod. Defaults: gm_construct map, sandbox, console open, native resolution from GMod's own config. " +
        "Workshop maps and player models work because the launcher boots into a stock bootstrap map first " +
        "and the addon transitions to the real target once Steam has finished mounting subscriptions. " +
        "The MCP bridge does NOT auto-enable; once GMod is running, the user must opt in via " +
        "`mcp_enable 1` in the developer console (and any required capability convars).";

    public JsonElement InputSchema { get; } = HostToolHelpers.ParseSchema("""
    {
      "type": "object",
      "properties": {
        "map":          { "type": "string",  "description": "Map to load (default: gm_construct). Workshop maps work — the launcher bootstraps gm_construct, waits for the workshop subscription to mount, then transitions to the target. Empty string boots to the main menu." },
        "gamemode":     { "type": "string",  "description": "Gamemode (default: sandbox)." },
        "console":      { "type": "boolean", "description": "Open the developer console window (default: true)." },
        "windowed":     { "type": "boolean", "description": "Force windowed (true) or fullscreen (false). Omit to keep whatever GMod has configured — that's the default and what the user usually wants." },
        "width":        { "type": "integer", "description": "Override window width. Omit to use GMod's configured resolution." },
        "height":       { "type": "integer", "description": "Override window height. Omit to use GMod's configured resolution." },
        "max_wait":     { "type": "integer", "description": "Safety-net cap on seconds to wait for workshop subscriptions to finish mounting before transitioning anyway (default: 60). Detection itself is event-driven on engine.GetAddons() — this only fires if Steam stalls." },
        "skip_bootstrap": { "type": "boolean", "description": "Skip the two-stage bootstrap and pass +map directly. Faster but breaks workshop content (default: false)." },
        "extra_args":   { "type": "array",   "items": { "type": "string" }, "description": "Extra arguments appended verbatim to the gmod.exe command line." }
      },
      "required": []
    }
    """);

    public ValueTask<CallToolResult> InvokeAsync(IDictionary<string, JsonElement>? args, CancellationToken ct)
    {
        var map = HostToolHelpers.GetString(args, "map", "gm_construct");
        var gamemode = HostToolHelpers.GetString(args, "gamemode", "sandbox");
        var console = HostToolHelpers.GetBool(args, "console", true);
        var windowed = HostToolHelpers.GetBoolOrNull(args, "windowed");
        var width = HostToolHelpers.GetIntOrNull(args, "width");
        var height = HostToolHelpers.GetIntOrNull(args, "height");
        var maxWait = HostToolHelpers.GetInt(args, "max_wait", 60);
        var skipBootstrap = HostToolHelpers.GetBool(args, "skip_bootstrap", false);
        var extra = HostToolHelpers.GetStringArray(args, "extra_args");

        // Decide whether to use the two-stage bootstrap. Direct mode (skip_bootstrap=true)
        // or "boot to menu" (empty map) goes straight to the legacy +map path.
        var useBootstrap = !skipBootstrap && !string.IsNullOrEmpty(map);

        // Stale intent files would re-fire on every launch — wipe before writing a new one.
        TryDeleteIntent();
        if (useBootstrap)
        {
            WriteIntent(map, gamemode, maxWait);
        }

        var bootMap = useBootstrap ? BootstrapMap : map;
        var bootGamemode = useBootstrap ? BootstrapGamemode : gamemode;

        var argList = new List<string>
        {
            "-game", "garrysmod",
            "-novid",
            "+sv_lan", "1",
        };

        if (console) argList.Add("-console");
        // Only override the user's display config when the caller explicitly
        // asked. Otherwise GMod boots in whatever resolution / mode the user
        // normally plays in.
        if (windowed == true) argList.Add("-windowed");
        else if (windowed == false) argList.Add("-fullscreen");
        if (width.HasValue) { argList.Add("-w"); argList.Add(width.Value.ToString()); }
        if (height.HasValue) { argList.Add("-h"); argList.Add(height.Value.ToString()); }
        if (!string.IsNullOrEmpty(bootGamemode))
        {
            argList.Add("+gamemode"); argList.Add(bootGamemode);
        }
        argList.AddRange(extra);
        if (!string.IsNullOrEmpty(bootMap))
        {
            argList.Add("+map"); argList.Add(bootMap);
        }

        try
        {
            var p = _proc.Launch(argList);
            var result = new JsonObject
            {
                ["ok"] = true,
                ["pid"] = p.Id,
                ["args"] = string.Join(" ", argList),
                ["bootstrap"] = useBootstrap
                    ? $"booting via {BootstrapMap}; will transition to {map} ({gamemode}) once engine.GetAddons() reports all downloaded subscriptions mounted (safety max_wait={maxWait}s)"
                    : "skip_bootstrap: passing +map directly; workshop maps/models may not load on first spawn",
                ["note"] = "GMod is launching. Once loaded, run `mcp_enable 1` (and any required capability convars, e.g. `mcp_allow_lua_eval 1`) in the developer console to enable tool dispatch.",
            };
            return ValueTask.FromResult(HostToolHelpers.Ok(result.ToJsonString()));
        }
        catch (Exception ex)
        {
            // If the launch failed, the intent file would otherwise sit around and
            // misfire on the user's next manual launch.
            TryDeleteIntent();
            var result = new JsonObject { ["ok"] = false, ["error"] = ex.Message };
            return ValueTask.FromResult(HostToolHelpers.Err(result.ToJsonString()));
        }
    }

    private string IntentPath => Path.Combine(_mcpRoot, "launch_intent.json");

    private void WriteIntent(string targetMap, string targetGamemode, int maxWait)
    {
        var intent = new JsonObject
        {
            ["target_map"] = targetMap,
            ["target_gamemode"] = targetGamemode,
            ["max_wait_seconds"] = maxWait,
        };
        File.WriteAllText(IntentPath, intent.ToJsonString());
    }

    private void TryDeleteIntent()
    {
        try
        {
            if (File.Exists(IntentPath)) File.Delete(IntentPath);
        }
        catch
        {
            // Best effort — a stale intent file is recoverable (the addon
            // single-shots it) and we don't want a transient I/O error to
            // block launches.
        }
    }
}
