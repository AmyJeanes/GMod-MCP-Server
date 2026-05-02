using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

public sealed class LaunchTool : IHostTool
{
    private const string BootstrapMap = "gm_construct";
    private const string BootstrapGamemode = "sandbox";
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);

    private readonly GameProcessManager _proc;
    private readonly BridgePinger _pinger;
    private readonly string _mcpRoot;

    public LaunchTool(GameProcessManager proc, BridgePinger pinger, BridgePaths paths)
    {
        _proc = proc;
        _pinger = pinger;
        _mcpRoot = paths.McpRoot;
    }

    public string Name => "host_launch";

    public string Description =>
        "Launch Garry's Mod and wait until the MCP bridge is fully ready before returning. " +
        "Defaults: gm_construct map, sandbox, console open, native resolution from GMod's own config. " +
        "Workshop maps and player models work because the launcher boots into a stock bootstrap map first " +
        "and the addon transitions to the real target once Steam has finished mounting subscriptions; " +
        "this tool blocks across both stages so callers don't have to poll. " +
        "Tool-dispatch convars (mcp_enable, mcp_allow_*) are FCVAR_ARCHIVE so once set they persist " +
        "across game restarts — no per-launch user step. If a convar isn't set yet, the tool times " +
        "out with a hint naming the missing convar; otherwise it returns ready with no user input.";

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
        "extra_args":   { "type": "array",   "items": { "type": "string" }, "description": "Extra arguments appended verbatim to the gmod.exe command line." },
        "wait_for_bridge": { "type": "boolean", "description": "Block until the bridge is reachable, mcp_enable is 1, and the bootstrap transition has completed (default: true). Set false for fire-and-forget launches." },
        "wait_timeout_seconds": { "type": "integer", "description": "How long to wait for the bridge to become ready before returning a timeout error (default: 180). Workshop boots can take 30-90s; the user also needs time to type `mcp_enable 1`." }
      },
      "required": []
    }
    """);

    public async ValueTask<CallToolResult> InvokeAsync(IDictionary<string, JsonElement>? args, CancellationToken ct)
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
        var waitForBridge = HostToolHelpers.GetBool(args, "wait_for_bridge", true);
        var waitTimeout = HostToolHelpers.GetInt(args, "wait_timeout_seconds", 180);

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

        Process p;
        try
        {
            p = _proc.Launch(argList);
        }
        catch (Exception ex)
        {
            // If the launch failed, the intent file would otherwise sit around and
            // misfire on the user's next manual launch.
            TryDeleteIntent();
            var failure = new JsonObject { ["ok"] = false, ["error"] = ex.Message };
            return HostToolHelpers.Err(failure.ToJsonString());
        }

        var bootstrapNote = useBootstrap
            ? $"booting via {BootstrapMap}; will transition to {map} ({gamemode}) once engine.GetAddons() reports all downloaded subscriptions mounted (safety max_wait={maxWait}s)"
            : "skip_bootstrap: passing +map directly; workshop maps/models may not load on first spawn";

        if (!waitForBridge)
        {
            var fireAndForget = new JsonObject
            {
                ["ok"] = true,
                ["pid"] = p.Id,
                ["args"] = string.Join(" ", argList),
                ["bootstrap"] = bootstrapNote,
                ["bridge_ready"] = false,
                ["note"] = "wait_for_bridge=false: returning immediately. Use host_status to check when the bridge is ready.",
            };
            return HostToolHelpers.Ok(fireAndForget.ToJsonString());
        }

        var timeout = TimeSpan.FromSeconds(waitTimeout);
        var (ready, lastPing, elapsed) = await WaitForReadyAsync(timeout, ct).ConfigureAwait(false);

        var result = new JsonObject
        {
            ["ok"] = ready,
            ["pid"] = p.Id,
            ["args"] = string.Join(" ", argList),
            ["bootstrap"] = bootstrapNote,
            ["bridge_ready"] = ready,
            ["wait_seconds"] = Math.Round(elapsed.TotalSeconds, 2),
            ["last_ping"] = new JsonObject
            {
                ["reachable"] = lastPing.Reachable,
                ["enabled"] = lastPing.Enabled,
                ["map"] = lastPing.Map,
                ["bootstrap_pending"] = lastPing.BootstrapPending,
            },
        };
        if (!ready)
        {
            result["error"] = ReadinessHint(lastPing, timeout);
            return HostToolHelpers.Err(result.ToJsonString());
        }
        return HostToolHelpers.Ok(result.ToJsonString());
    }

    private async Task<(bool Ready, BridgePingResult Last, TimeSpan Elapsed)> WaitForReadyAsync(
        TimeSpan timeout, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        var last = default(BridgePingResult);
        while (sw.Elapsed < timeout)
        {
            ct.ThrowIfCancellationRequested();
            last = await _pinger.PingAsync(ct).ConfigureAwait(false);
            if (last.Reachable && last.Enabled == true && last.BootstrapPending != true)
            {
                sw.Stop();
                return (true, last, sw.Elapsed);
            }

            try { await Task.Delay(PollInterval, ct).ConfigureAwait(false); }
            catch (TaskCanceledException) { break; }
        }
        sw.Stop();
        return (false, last, sw.Elapsed);
    }

    private static string ReadinessHint(BridgePingResult last, TimeSpan timeout)
    {
        if (!last.Reachable)
        {
            return $"Timed out after {timeout.TotalSeconds:F0}s waiting for the bridge to respond. "
                + "GMod may still be loading, may have crashed, or `mcp_enable` was never set.";
        }
        if (last.BootstrapPending == true)
        {
            return $"Timed out after {timeout.TotalSeconds:F0}s; bridge reachable but the bootstrap transition "
                + "didn't complete. Workshop mount may have stalled — check the GMod console for errors.";
        }
        if (last.Enabled == false)
        {
            return $"Timed out after {timeout.TotalSeconds:F0}s; bridge reachable but mcp_enable is still 0. "
                + "Run `mcp_enable 1` in the GMod developer console to allow tool dispatch.";
        }
        return $"Timed out after {timeout.TotalSeconds:F0}s waiting for the bridge to become ready.";
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
