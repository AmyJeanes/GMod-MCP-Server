using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace GModMcpServer.Bridge;

/// <summary>
/// Single source of truth for sending <c>_ping</c> to GMod and decoding the
/// reply. Used both by <c>host_status</c> for one-shot diagnostics and by
/// <c>host_launch</c> for the post-launch readiness wait.
/// </summary>
public sealed class BridgePinger
{
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromMilliseconds(1500);

    private readonly FileBridgeRegistry _bridges;

    public BridgePinger(FileBridgeRegistry bridges)
    {
        _bridges = bridges;
    }

    public Task<BridgePingResult> PingAsync(CancellationToken ct)
        => PingAsync(DefaultTimeout, ct);

    public async Task<BridgePingResult> PingAsync(TimeSpan timeout, CancellationToken ct)
    {
        try
        {
            var bridge = _bridges.Get("server");
            using var doc = JsonDocument.Parse("{}");
            var emptyArgs = doc.RootElement.Clone();

            var sw = Stopwatch.StartNew();
            var resp = await bridge.SendAsync("_ping", emptyArgs, timeout, ct).ConfigureAwait(false);
            sw.Stop();

            bool? enabled = null;
            string? map = null;
            bool? bootstrapPending = null;
            if (resp.Result is JsonObject obj)
            {
                if (obj.TryGetPropertyValue("enabled", out var enNode)
                    && enNode is JsonValue enVal
                    && enVal.TryGetValue<bool>(out var enBool))
                {
                    enabled = enBool;
                }

                if (obj.TryGetPropertyValue("map", out var mapNode)
                    && mapNode is JsonValue mapVal
                    && mapVal.TryGetValue<string>(out var mapStr))
                {
                    map = mapStr;
                }

                if (obj.TryGetPropertyValue("bootstrap_pending", out var bpNode)
                    && bpNode is JsonValue bpVal
                    && bpVal.TryGetValue<bool>(out var bpBool))
                {
                    bootstrapPending = bpBool;
                }
            }

            return new BridgePingResult(true, sw.Elapsed.TotalMilliseconds, enabled, map, bootstrapPending);
        }
        catch (TaskCanceledException)
        {
            return new BridgePingResult(false, null, null, null, null);
        }
        catch (Exception)
        {
            return new BridgePingResult(false, null, null, null, null);
        }
    }
}

public readonly record struct BridgePingResult(
    bool Reachable,
    double? LatencyMs,
    bool? Enabled,
    string? Map,
    bool? BootstrapPending);
