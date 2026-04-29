using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

public sealed class StatusTool : IHostTool
{
    private static readonly TimeSpan PingTimeout = TimeSpan.FromMilliseconds(1500);

    private readonly GameProcessManager _proc;
    private readonly ManifestWatcher _manifest;
    private readonly FileBridgeRegistry _bridges;

    public StatusTool(GameProcessManager proc, ManifestWatcher manifest, FileBridgeRegistry bridges)
    {
        _proc = proc;
        _manifest = manifest;
        _bridges = bridges;
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

        var capabilities = new JsonArray();
        foreach (var cap in manifest.Capabilities.Values)
        {
            capabilities.Add(new JsonObject
            {
                ["id"] = cap.Id,
                ["convar"] = cap.ConVar,
                ["current"] = cap.Current,
                ["default"] = cap.Default,
            });
        }

        var bridgeNode = new JsonObject
        {
            ["tools"] = manifest.Tools.Count,
            ["capabilities"] = capabilities,
        };

        if (snap.Running)
        {
            var ping = await PingAsync(ct).ConfigureAwait(false);
            bridgeNode["reachable"] = ping.Reachable;
            bridgeNode["latency_ms"] = ping.LatencyMs;
            bridgeNode["enabled"] = ping.Enabled;
            if (!ping.Reachable)
            {
                bridgeNode["hint"] = "GMod is running but the bridge didn't respond within "
                    + (int)PingTimeout.TotalMilliseconds + " ms — likely still loading, or paused on a menu.";
            }
            else if (ping.Enabled == false)
            {
                bridgeNode["hint"] = "Bridge reachable but mcp_enable is 0. Run `mcp_enable 1` in the GMod console to allow tool dispatch.";
            }
        }
        else
        {
            bridgeNode["reachable"] = false;
            bridgeNode["latency_ms"] = null;
            bridgeNode["enabled"] = null;
        }

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

    private async Task<PingResult> PingAsync(CancellationToken ct)
    {
        try
        {
            var bridge = _bridges.Get("server");
            using var doc = JsonDocument.Parse("{}");
            var emptyArgs = doc.RootElement.Clone();

            var sw = Stopwatch.StartNew();
            var resp = await bridge.SendAsync("_ping", emptyArgs, PingTimeout, ct).ConfigureAwait(false);
            sw.Stop();

            bool? enabled = null;
            if (resp.Result is JsonObject obj
                && obj.TryGetPropertyValue("enabled", out var enNode)
                && enNode is JsonValue enVal
                && enVal.TryGetValue<bool>(out var enBool))
            {
                enabled = enBool;
            }

            return new PingResult(true, sw.Elapsed.TotalMilliseconds, enabled);
        }
        catch (TaskCanceledException)
        {
            return new PingResult(false, null, null);
        }
        catch (Exception)
        {
            return new PingResult(false, null, null);
        }
    }

    private readonly record struct PingResult(bool Reachable, double? LatencyMs, bool? Enabled);
}
