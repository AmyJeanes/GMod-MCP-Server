using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using GModMcpServer.Models;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

/// <summary>
/// Changes the map of an already-running GMod server and blocks until the new map
/// is ready — the in-game sibling of <see cref="LaunchTool"/>. The map command
/// tears down the server Lua state, so readiness can't ride on an in-memory
/// handler: the GMod side (<c>_changelevel</c> → <c>MCP:RequestLevelChange</c>)
/// drops a disk marker that keeps <c>bootstrap_pending</c> true across the
/// teardown until the new map's <c>InitPostEntity</c>, and this tool polls
/// <c>_ping</c> via the shared <see cref="BridgePinger.WaitUntilReadyAsync"/>.
///
/// Deliberately depends only on the bridge (no <c>GameProcessManager</c>): the
/// "is GMod running?" check is the ping itself, which keeps the whole flow
/// constructible in tests over a temp dir + fake responder.
/// </summary>
public sealed class ChangeLevelTool : IHostTool
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan TriggerTimeout = TimeSpan.FromSeconds(5);

    private readonly BridgePinger _pinger;
    private readonly FileBridgeRegistry _bridges;
    private readonly string _mcpRoot;

    public ChangeLevelTool(BridgePinger pinger, FileBridgeRegistry bridges, BridgePaths paths)
    {
        _pinger = pinger;
        _bridges = bridges;
        _mcpRoot = paths.McpRoot;
    }

    public string Name => "host_changelevel";

    public string Description =>
        "Change the map of the already-running GMod server and block until the new map is ready " +
        "before returning (the in-game sibling of host_launch's readiness wait). Requires GMod running " +
        "with mcp_enable 1. Defaults to a soft `changelevel`; pass hard_reset for a full `map` restart, " +
        "or a gamemode to switch gamemode (which forces a full restart). Reloading the same map is fine. " +
        "The target is validated against installed maps first, so a bad name fails fast instead of " +
        "hanging. To cold-start GMod, or to switch singleplayer<->listen (maxplayers is fixed at launch), " +
        "use host_launch instead.";

    public JsonElement InputSchema { get; } = HostToolHelpers.ParseSchema("""
    {
      "type": "object",
      "properties": {
        "map":          { "type": "string",  "description": "Target map to load (e.g. gm_flatgrass). Validated against installed maps; workshop maps work since they're already mounted." },
        "gamemode":     { "type": "string",  "description": "Switch to this gamemode. A gamemode change only takes effect on a full server restart, so supplying this forces hard_reset behaviour." },
        "hard_reset":   { "type": "boolean", "description": "Use a full `map` restart instead of a soft `changelevel` (default: false)." },
        "wait_for_ready": { "type": "boolean", "description": "Block until the new map's bridge is ready before returning (default: true). Set false to fire-and-forget." },
        "wait_timeout_seconds": { "type": "integer", "description": "How long to wait for the new map to come up before returning a timeout error (default: 120)." }
      },
      "required": ["map"]
    }
    """);

    public async ValueTask<CallToolResult> InvokeAsync(IDictionary<string, JsonElement>? args, CancellationToken ct)
    {
        var map = HostToolHelpers.GetString(args, "map", "");
        if (string.IsNullOrWhiteSpace(map))
        {
            return Err("`map` is required.");
        }
        var gamemode = HostToolHelpers.GetString(args, "gamemode", "");
        var hardReset = HostToolHelpers.GetBool(args, "hard_reset", false);
        var waitForReady = HostToolHelpers.GetBool(args, "wait_for_ready", true);
        var waitTimeout = HostToolHelpers.GetInt(args, "wait_timeout_seconds", 120);

        // Pre-check: the bridge must be reachable, consented, and not already
        // mid-transition. The ping doubles as the "is GMod running?" check.
        var pre = await _pinger.PingAsync(ct).ConfigureAwait(false);
        if (!pre.Reachable)
        {
            return Err("GMod isn't reachable over the bridge. Launch it with host_launch (or it may still be loading / paused on a menu).");
        }
        if (pre.Enabled == false)
        {
            return Err("Bridge reachable but mcp_enable is 0. Run `mcp_enable 1` in the GMod console.");
        }
        if (pre.BootstrapPending == true)
        {
            return Err("A launch/level transition is already in progress; wait for it to finish (poll host_status).");
        }

        // Trigger the change on the server realm. The handler validates the map,
        // sets bootstrap_pending, writes the level_change marker, and issues the
        // command at end of frame — after this response file is written.
        var triggerArgs = new JsonObject { ["map"] = map };
        if (!string.IsNullOrEmpty(gamemode)) triggerArgs["gamemode"] = gamemode;
        if (hardReset) triggerArgs["hard_reset"] = true;
        var triggerElement = JsonSerializer.Deserialize<JsonElement>(triggerArgs.ToJsonString());

        BridgeResponse trigger;
        try
        {
            trigger = await _bridges.Get("server")
                .SendAsync("_changelevel", triggerElement, TriggerTimeout, ct)
                .ConfigureAwait(false);
        }
        catch (TaskCanceledException)
        {
            return Err("Timed out asking GMod to change level (bridge stopped responding).");
        }

        if (!ResultIsOk(trigger.Result))
        {
            var err = (trigger.Result as JsonObject)?["error"]?.GetValue<string>()
                ?? "level change was rejected by GMod.";
            return Err(err);
        }

        if (!waitForReady)
        {
            return HostToolHelpers.Ok(new JsonObject
            {
                ["ok"] = true,
                ["map"] = map,
                ["bridge_ready"] = false,
                ["note"] = "wait_for_ready=false: returning immediately. Use host_status to check when the new map is ready.",
            }.ToJsonString());
        }

        var timeout = TimeSpan.FromSeconds(waitTimeout);
        var (ready, last, elapsed) = await _pinger.WaitUntilReadyAsync(timeout, PollInterval, ct).ConfigureAwait(false);

        var result = new JsonObject
        {
            ["ok"] = ready,
            ["map"] = last.Map ?? map,
            ["bridge_ready"] = ready,
            ["wait_seconds"] = Math.Round(elapsed.TotalSeconds, 2),
            ["last_ping"] = new JsonObject
            {
                ["reachable"] = last.Reachable,
                ["enabled"] = last.Enabled,
                ["map"] = last.Map,
                ["bootstrap_pending"] = last.BootstrapPending,
                ["bootstrap_error"] = last.BootstrapError,
            },
        };

        if (!ready)
        {
            // Best-effort: clear the marker so a stuck transition doesn't poison
            // the next boot's eager check (the GMod-side fallback also self-clears).
            TryDeleteMarker();
            result["error"] = last.BootstrapError
                ?? $"Timed out after {timeout.TotalSeconds:F0}s waiting for '{map}' to load.";
            return HostToolHelpers.Err(result.ToJsonString());
        }

        return HostToolHelpers.Ok(result.ToJsonString());
    }

    private static bool ResultIsOk(JsonNode? result) =>
        result is JsonObject obj
        && obj.TryGetPropertyValue("ok", out var okNode)
        && okNode is JsonValue okVal
        && okVal.TryGetValue<bool>(out var okBool)
        && okBool;

    private static CallToolResult Err(string message) =>
        HostToolHelpers.Err(new JsonObject { ["ok"] = false, ["error"] = message }.ToJsonString());

    private void TryDeleteMarker()
    {
        try
        {
            var marker = Path.Combine(_mcpRoot, "level_change.json");
            if (File.Exists(marker)) File.Delete(marker);
        }
        catch
        {
            // best effort
        }
    }
}
