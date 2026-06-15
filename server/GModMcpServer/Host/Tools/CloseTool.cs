using System.Text.Json;
using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

public sealed class CloseTool : IHostTool
{
    private readonly GameProcessManager _proc;

    public CloseTool(GameProcessManager proc) { _proc = proc; }

    public string Name => "host_close";

    public string Description =>
        "Close the running GMod process (located by name, regardless of who launched it). " +
        "By default does a clean shutdown — posts the window-close signal so GMod saves its " +
        "config, which is the only way capability grants (mcp_allow_*) and mcp_enable set this " +
        "session persist to the next launch — waiting up to graceful_seconds before falling back " +
        "to a kill. Pass force=true to skip straight to killing the process tree (faster, but the " +
        "config is not saved so this-session grants are lost).";

    public JsonElement InputSchema { get; } = HostToolHelpers.ParseSchema("""
    {
      "type": "object",
      "properties": {
        "force":            { "type": "boolean", "description": "Kill the process tree immediately instead of a clean shutdown. Faster, but GMod won't save its config — capability grants and mcp_enable set this session are lost (default: false)." },
        "graceful_seconds": { "type": "number",  "description": "How long to wait for the clean shutdown to finish before falling back to a kill (default: 10). Ignored when force=true." }
      },
      "required": []
    }
    """);

    public ValueTask<CallToolResult> InvokeAsync(IDictionary<string, JsonElement>? args, CancellationToken ct)
    {
        var force = HostToolHelpers.GetBool(args, "force", false);
        var seconds = 10.0;
        if (args is not null && args.TryGetValue("graceful_seconds", out var v)
            && v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var s))
        {
            seconds = Math.Max(0, s);
        }

        var method = force ? _proc.Close(TimeSpan.Zero) : _proc.Close(TimeSpan.FromSeconds(seconds));

        if (method == CloseMethod.NotRunning)
        {
            var notRunning = new JsonObject { ["ok"] = true, ["closed"] = false, ["reason"] = "no gmod.exe process is currently running" };
            return ValueTask.FromResult(HostToolHelpers.Ok(notRunning.ToJsonString()));
        }

        var clean = method == CloseMethod.CleanWindowClose;
        var result = new JsonObject
        {
            ["ok"] = true,
            ["closed"] = true,
            ["method"] = method switch
            {
                CloseMethod.CleanWindowClose => "clean",
                CloseMethod.KilledAfterTimeout => "killed_after_timeout",
                _ => "killed",
            },
            ["config_saved"] = clean,
        };
        if (method == CloseMethod.KilledAfterTimeout)
        {
            result["note"] = "Clean shutdown didn't finish within graceful_seconds; killed. GMod config (capability grants) may not have been saved.";
        }
        else if (method == CloseMethod.Killed)
        {
            result["note"] = force
                ? "Force-killed as requested; GMod config was not saved, so capability grants set this session won't persist."
                : "Killed without a clean shutdown; GMod config was not saved, so capability grants set this session won't persist.";
        }
        return ValueTask.FromResult(HostToolHelpers.Ok(result.ToJsonString()));
    }
}
