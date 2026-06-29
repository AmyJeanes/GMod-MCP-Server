using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

/// <summary>
/// Reloads the in-game MCP addon (re-runs its Lua and restarts the bridge) and
/// blocks until the bridge is back and ready — the host-managed sibling of running
/// <c>mcp_reload</c> in the GMod console, without the timeout a bare reload causes.
///
/// Restarting the bridge clears the IPC dirs mid-frame, so the <c>_reload</c>
/// trigger's own response is reliably eaten before the host can read it. Unlike
/// <see cref="ChangeLevelTool"/> there's no disk marker: the Lua state isn't torn
/// down, so <c>MCP._generation</c> (bumped by <c>MCP:Reload</c>) survives in memory
/// and its advance — reported by <c>_ping</c> — is the completion signal.
///
/// Deliberately depends only on the bridge (no <c>GameProcessManager</c>): the
/// "is GMod running?" check is the pre-ping itself.
/// </summary>
public sealed class ReloadTool : IHostTool
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan PingTimeout = TimeSpan.FromMilliseconds(1500);
    private static readonly TimeSpan TriggerTimeout = TimeSpan.FromSeconds(2);

    private readonly BridgePinger _pinger;
    private readonly FileBridgeRegistry _bridges;

    public ReloadTool(BridgePinger pinger, FileBridgeRegistry bridges)
    {
        _pinger = pinger;
        _bridges = bridges;
    }

    public string Name => "mcp_reload";

    public string Description =>
        "Reload the in-game MCP addon (re-run its Lua and restart the bridge) and block until the bridge " +
        "is back and ready before returning — the host-managed equivalent of running `mcp_reload` in the " +
        "GMod console, but without the timeout a bare reload causes (the reload tears the bridge down " +
        "mid-call). Use after adding or deleting a tool file, or when autorefresh hasn't picked up an edit. " +
        "Requires GMod running with mcp_enable 1.";

    public JsonElement InputSchema { get; } = HostToolHelpers.ParseSchema("""
    {
      "type": "object",
      "properties": {
        "wait_for_ready":        { "type": "boolean", "description": "Block until the reloaded bridge is ready before returning (default: true). Set false to fire-and-forget." },
        "wait_timeout_seconds":  { "type": "integer", "description": "How long to wait for the bridge to come back before returning a timeout error (default: 30)." }
      }
    }
    """);

    public async ValueTask<CallToolResult> InvokeAsync(IDictionary<string, JsonElement>? args, CancellationToken ct)
    {
        var waitForReady = HostToolHelpers.GetBool(args, "wait_for_ready", true);
        var waitTimeout = HostToolHelpers.GetInt(args, "wait_timeout_seconds", 30);

        // Pre-check, and capture each realm's current generation so we can tell a
        // genuine reload from pinging the pre-reload bridge. The ping doubles as the
        // "is GMod running?" check.
        var preServer = await _pinger.PingAsync("server", PingTimeout, ct).ConfigureAwait(false);
        if (!preServer.Reachable)
        {
            return Err("GMod isn't reachable over the bridge. Launch it with host_launch (or it may still be loading / paused on a menu).");
        }
        if (preServer.Enabled == false)
        {
            return Err("Bridge reachable but mcp_enable is 0. Run `mcp_enable 1` in the GMod console.");
        }
        var preClient = await _pinger.PingAsync("client", PingTimeout, ct).ConfigureAwait(false);

        var serverGen0 = preServer.Generation ?? 0;
        var clientGen0 = preClient.Generation ?? 0;

        // Fire the reload on the server realm (the handler also broadcasts to
        // clients). Its response is expected to be eaten when StartBridge clears
        // the out dir mid-frame, so a timeout here is normal — swallow it and rely
        // on the generation bump below.
        using var doc = JsonDocument.Parse("{}");
        try
        {
            await _bridges.Get("server").SendAsync("_reload", doc.RootElement.Clone(), TriggerTimeout, ct).ConfigureAwait(false);
        }
        catch (TaskCanceledException)
        {
            // Expected: the reload tore the bridge down before the reply was read.
        }

        if (!waitForReady)
        {
            return HostToolHelpers.Ok(new JsonObject
            {
                ["ok"] = true,
                ["bridge_ready"] = false,
                ["note"] = "wait_for_ready=false: returning immediately. Use host_status to confirm the bridge is back.",
            }.ToJsonString());
        }

        // Poll both realms until each generation has advanced past its pre-reload
        // value and the bridge reports ready again, or we time out.
        var timeout = TimeSpan.FromSeconds(waitTimeout);
        var sw = Stopwatch.StartNew();
        var server = default(BridgePingResult);
        var client = default(BridgePingResult);
        var reloaded = false;
        while (sw.Elapsed < timeout)
        {
            ct.ThrowIfCancellationRequested();
            server = await _pinger.PingAsync("server", PingTimeout, ct).ConfigureAwait(false);
            client = await _pinger.PingAsync("client", PingTimeout, ct).ConfigureAwait(false);

            var serverDone = server.Reachable && server.Enabled == true && (server.Generation ?? 0) > serverGen0;
            var clientDone = client.Reachable && client.Enabled == true && (client.Generation ?? 0) > clientGen0;
            if (serverDone && clientDone)
            {
                reloaded = true;
                break;
            }

            try { await Task.Delay(PollInterval, ct).ConfigureAwait(false); }
            catch (TaskCanceledException) { break; }
        }
        sw.Stop();

        var result = new JsonObject
        {
            ["ok"] = reloaded,
            ["bridge_ready"] = reloaded,
            ["wait_seconds"] = Math.Round(sw.Elapsed.TotalSeconds, 2),
            ["server_generation"] = server.Generation,
            ["client_generation"] = client.Generation,
        };

        if (!reloaded)
        {
            result["error"] = $"Timed out after {timeout.TotalSeconds:F0}s waiting for the reloaded bridge to come back ready.";
            return HostToolHelpers.Err(result.ToJsonString());
        }

        return HostToolHelpers.Ok(result.ToJsonString());
    }

    private static CallToolResult Err(string message) =>
        HostToolHelpers.Err(new JsonObject { ["ok"] = false, ["error"] = message }.ToJsonString());
}
