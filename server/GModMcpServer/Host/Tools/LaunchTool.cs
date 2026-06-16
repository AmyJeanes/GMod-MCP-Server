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
        "Defaults: gm_construct map, sandbox, console open, native resolution from GMod's own config, " +
        "singleplayer (pass maxplayers > 1 to boot a listen/multiplayer server instead). " +
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
        "maxplayers":   { "type": "integer", "description": "Player slots, 1-128. Omit or 1 = singleplayer (default). >1 boots a LISTEN (multiplayer) server — needed for bots, a second client, or any multiplayer-only behaviour. Fixed at launch: maxplayers can't change on a running game, so switching modes means host_close then host_launch." },
        "console":      { "type": "boolean", "description": "Open the developer console window (default: true)." },
        "windowed":     { "type": "boolean", "description": "Force windowed (true) or fullscreen (false). Omit to keep whatever GMod has configured — that's the default and what the user usually wants." },
        "width":        { "type": "integer", "description": "Override window width. Omit to use GMod's configured resolution." },
        "height":       { "type": "integer", "description": "Override window height. Omit to use GMod's configured resolution." },
        "max_wait":     { "type": "integer", "description": "Safety-net cap on seconds to wait for workshop subscriptions to finish mounting before transitioning anyway (default: 60). Detection itself is event-driven on engine.GetAddons() — this only fires if Steam stalls." },
        "skip_bootstrap": { "type": "boolean", "description": "Skip the two-stage bootstrap and pass +map directly. Faster but breaks workshop content (default: false)." },
        "extra_args":   { "type": "array",   "items": { "type": "string" }, "description": "Extra arguments appended verbatim to the gmod.exe command line." },
        "wait_for_bridge": { "type": "boolean", "description": "Block until the bridge is reachable, mcp_enable is 1, and the bootstrap transition has completed (default: true). Set false for fire-and-forget launches." },
        "wait_timeout_seconds": { "type": "integer", "description": "How long to wait for the bridge to become ready before returning a timeout error (default: 180). Workshop boots can take 30-90s; the user also needs time to type `mcp_enable 1`." },
        "fix_focus":    { "type": "boolean", "description": "After the bridge is ready, if GMod was launched into the background and its window grabbed the mouse (a GMod/SDL startup-focus bug), give the window a brief real focus cycle to release the cursor. Only fires when actually stuck (gmod isn't the OS foreground window AND it still thinks it's focused), so normal launches are untouched; causes a brief focus blip. Windows-only. Default: true." }
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
        var maxPlayers = HostToolHelpers.GetIntOrNull(args, "maxplayers");
        var fixFocus = HostToolHelpers.GetBool(args, "fix_focus", true);

        if (maxPlayers is int requested && (requested < 1 || requested > 128))
        {
            var bad = new JsonObject { ["ok"] = false, ["error"] = $"maxplayers must be between 1 and 128 (got {requested})." };
            return HostToolHelpers.Err(bad.ToJsonString());
        }

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
        if (maxPlayers is int slots && slots > 1)
        {
            // maxplayers is locked at the first server init, so it must be on
            // the command line: the bootstrap's gm_construct boot then comes up
            // multiplayer and the map transition preserves the slot count.
            argList.Add("+maxplayers"); argList.Add(slots.ToString());
        }
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
        var (ready, server, client, elapsed) = await _pinger.WaitUntilReadyAsync(timeout, PollInterval, ct).ConfigureAwait(false);

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
                ["reachable"] = server.Reachable,
                ["enabled"] = server.Enabled,
                ["map"] = server.Map,
                ["maxplayers"] = server.MaxPlayers,
                ["singleplayer"] = server.SinglePlayer,
                ["bootstrap_pending"] = server.BootstrapPending,
                ["bootstrap_error"] = server.BootstrapError,
            },
            ["client_ping"] = new JsonObject
            {
                ["reachable"] = client.Reachable,
                ["enabled"] = client.Enabled,
                ["has_focus"] = client.HasFocus,
            },
        };
        if (!ready)
        {
            result["error"] = ReadinessHint(server, client, timeout);
            return HostToolHelpers.Err(result.ToJsonString());
        }

        // Background-launch stuck-focus workaround (Windows-only; opt out via fix_focus).
        // Only acts when actually stuck, so a normal launch gets no focus blip.
        if (fixFocus && OperatingSystem.IsWindows())
        {
            result["focus_reconcile"] = await ReconcileFocusAsync(client, ct).ConfigureAwait(false);
        }

        return HostToolHelpers.Ok(result.ToJsonString());
    }

    private static string ReadinessHint(BridgePingResult server, BridgePingResult client, TimeSpan timeout)
    {
        if (server.BootstrapError != null)
        {
            return server.BootstrapError;
        }
        if (!server.Reachable)
        {
            return $"Timed out after {timeout.TotalSeconds:F0}s waiting for the bridge to respond. "
                + "GMod may still be loading, may have crashed, or `mcp_enable` was never set.";
        }
        if (server.BootstrapPending == true)
        {
            return $"Timed out after {timeout.TotalSeconds:F0}s; bridge reachable but the bootstrap transition "
                + "didn't complete. Workshop mount may have stalled — check the GMod console for errors.";
        }
        if (server.Enabled == false)
        {
            return $"Timed out after {timeout.TotalSeconds:F0}s; bridge reachable but mcp_enable is still 0. "
                + "Run `mcp_enable 1` in the GMod developer console to allow tool dispatch.";
        }
        if (!client.Reachable || client.Enabled != true)
        {
            return $"Timed out after {timeout.TotalSeconds:F0}s; the server realm is ready but the client realm "
                + "didn't become ready (its bridge may still be initialising).";
        }
        return $"Timed out after {timeout.TotalSeconds:F0}s waiting for the bridge to become ready.";
    }

    // Detects and clears GMod's stuck mouse-grab after a background launch. The bug:
    // GMod missed the OS focus-lost during the startup race, so it thinks it's focused
    // and grabs the mouse while in the background. Detection needs BOTH signals — the
    // OS view (gmod isn't foreground) AND the game's belief (client has_focus == true);
    // together they separate "stuck while background" (fix) from "really focused"
    // (leave alone). The fix is a real focus flicker (GameProcessManager.FlickerFocus),
    // applied with an escalating settle and verified via has_focus so we use the
    // shortest pause that actually heals. Best-effort: never fails the launch.
    private async Task<JsonObject> ReconcileFocusAsync(BridgePingResult client, CancellationToken ct)
    {
        var foreground = _proc.IsForeground();
        var stuck = !foreground && client.HasFocus == true;
        var node = new JsonObject
        {
            ["attempted"] = true,
            ["foreground_at_check"] = foreground,
            ["detected_stuck"] = stuck,
        };
        if (!stuck)
        {
            node["resolved"] = false;
            node["flickers"] = 0;
            node["note"] = foreground
                ? "GMod is the foreground window; nothing to reconcile."
                : "Client reports it is not focused; no stuck mouse-grab to fix.";
            return node;
        }

        // Escalating settle: try "instant" first, grow only if has_focus didn't heal.
        int[] settles = { 0, 50, 150, 400 };
        var flickers = 0;
        var resolved = false;
        foreach (var settle in settles)
        {
            if (_proc.IsForeground()) break; // user clicked into the game — leave it
            _proc.FlickerFocus(settle);
            flickers++;
            var check = await _pinger.PingAsync("client", TimeSpan.FromSeconds(2), ct).ConfigureAwait(false);
            if (check.HasFocus == false) { resolved = true; break; }
        }

        node["resolved"] = resolved;
        node["flickers"] = flickers;
        if (!resolved)
        {
            node["note"] = "Flicker did not heal the stuck focus within the settle budget; "
                + "the cursor may stay grabbed until you alt-tab into GMod.";
        }
        return node;
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
