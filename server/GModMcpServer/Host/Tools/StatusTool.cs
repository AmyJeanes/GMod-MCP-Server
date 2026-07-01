using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

public sealed class StatusTool : IHostTool
{
    private readonly GameProcessManager _proc;
    private readonly ManifestWatcher _manifest;
    private readonly BridgePinger _pinger;

    public StatusTool(GameProcessManager proc, ManifestWatcher manifest, BridgePinger pinger)
    {
        _proc = proc;
        _manifest = manifest;
        _pinger = pinger;
    }

    public string Name => "host_status";

    public string Description =>
        "Report whether GMod is running, whether the MCP bridge is reachable (a live ping is " +
        "sent when GMod is detected), and the current tool count and capability state. " +
        "Useful for diagnosing why a tool call isn't working.";

    public JsonElement InputSchema { get; } = HostToolHelpers.ParseSchema("""
    { "type": "object", "properties": {}, "required": [] }
    """);

    public async ValueTask<CallToolResult> InvokeAsync(IDictionary<string, JsonElement>? args, CancellationToken ct)
    {
        var snap = _proc.Snapshot();
        var manifest = _manifest.Current;

        var bridgeNode = new JsonObject
        {
            ["tools"] = manifest.Tools.Count,
        };

        BridgePingResult? ping = null;
        if (snap.Running)
        {
            var p = await _pinger.PingAsync(ct).ConfigureAwait(false);
            ping = p;
            bridgeNode["reachable"] = p.Reachable;
            bridgeNode["latency_ms"] = p.LatencyMs;
            bridgeNode["enabled"] = p.Enabled;
            bridgeNode["map"] = p.Map;
            bridgeNode["maxplayers"] = p.MaxPlayers;
            bridgeNode["singleplayer"] = p.SinglePlayer;
            bridgeNode["bootstrap_pending"] = p.BootstrapPending;
            bridgeNode["bootstrap_error"] = p.BootstrapError;
            if (p.BootstrapError != null)
            {
                bridgeNode["hint"] = p.BootstrapError;
            }
            else if (!p.Reachable)
            {
                bridgeNode["hint"] = "GMod is running but the bridge didn't respond — likely still loading, or paused on a menu.";
            }
            else if (p.BootstrapPending == true)
            {
                bridgeNode["hint"] = "Bridge reachable but the host_launch bootstrap is still in progress (workshop mount or post-mount map transition).";
            }
            else if (p.Enabled == false)
            {
                bridgeNode["hint"] = "Bridge reachable but mcp_enable is 0. Run `mcp_enable 1` in the GMod console to allow tool dispatch.";
            }
        }
        else
        {
            bridgeNode["reachable"] = false;
            bridgeNode["latency_ms"] = null;
            bridgeNode["enabled"] = null;
            bridgeNode["map"] = null;
            bridgeNode["maxplayers"] = null;
            bridgeNode["singleplayer"] = null;
            bridgeNode["bootstrap_pending"] = null;
        }

        // Capabilities: prefer the live convar values carried on the ping (so a convar
        // flipped after registration reads correctly); fall back to the manifest snapshot
        // when GMod is down or the ping carried none (older addon build).
        var capabilities = new JsonArray();
        foreach (var cap in manifest.Capabilities.Values)
        {
            var current = cap.Current;
            if (ping is { Capabilities: { } liveCaps } && liveCaps.TryGetValue(cap.Id, out var liveVal))
            {
                current = liveVal;
            }
            capabilities.Add(new JsonObject
            {
                ["id"] = cap.Id,
                ["convar"] = cap.ConVar,
                ["current"] = current,
                ["default"] = cap.Default,
            });
        }
        bridgeNode["capabilities"] = capabilities;

        var result = new JsonObject
        {
            ["ok"] = true,
            ["gmod"] = new JsonObject
            {
                ["running"] = snap.Running,
                ["pid"] = snap.Pid,
                ["uptime_seconds"] = snap.Uptime?.TotalSeconds,
                ["last_launch_args"] = string.IsNullOrEmpty(snap.LastArgs) ? null : snap.LastArgs,
            },
            ["bridge"] = bridgeNode,
        };

        return HostToolHelpers.Ok(result.ToJsonString());
    }
}
