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
            int? maxPlayers = null;
            bool? singlePlayer = null;
            string? bootstrapError = null;
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

                // Lua numbers are doubles, so a whole value may arrive as 2 or
                // 2.0 depending on the encoder — accept either.
                if (obj.TryGetPropertyValue("maxplayers", out var mpNode) && mpNode is JsonValue mpVal)
                {
                    if (mpVal.TryGetValue<int>(out var mpInt)) maxPlayers = mpInt;
                    else if (mpVal.TryGetValue<double>(out var mpDbl)) maxPlayers = (int)mpDbl;
                }

                if (obj.TryGetPropertyValue("singleplayer", out var spNode)
                    && spNode is JsonValue spVal
                    && spVal.TryGetValue<bool>(out var spBool))
                {
                    singlePlayer = spBool;
                }

                if (obj.TryGetPropertyValue("bootstrap_error", out var beNode)
                    && beNode is JsonValue beVal
                    && beVal.TryGetValue<string>(out var beStr))
                {
                    bootstrapError = beStr;
                }
            }

            return new BridgePingResult(true, sw.Elapsed.TotalMilliseconds, enabled, map, bootstrapPending, maxPlayers, singlePlayer, bootstrapError);
        }
        catch (TaskCanceledException)
        {
            return new BridgePingResult(false, null, null, null, null, null, null, null);
        }
        catch (Exception)
        {
            return new BridgePingResult(false, null, null, null, null, null, null, null);
        }
    }

    /// <summary>
    /// Polls <c>_ping</c> until the bridge is ready — reachable, <c>mcp_enable</c>
    /// on, and no launch/level transition pending — or <paramref name="timeout"/>
    /// elapses. Bails early with <c>Ready = false</c> if the addon reports a
    /// terminal <c>bootstrap_error</c>; that's checked <em>before</em> the ready
    /// condition because the failure path also clears <c>bootstrap_pending</c>, so
    /// the naive ready check would otherwise treat a failed transition as success.
    /// Shared by <c>host_launch</c> and <c>host_changelevel</c>.
    /// </summary>
    public async Task<(bool Ready, BridgePingResult Last, TimeSpan Elapsed)> WaitUntilReadyAsync(
        TimeSpan timeout, TimeSpan pollInterval, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        var last = default(BridgePingResult);
        while (sw.Elapsed < timeout)
        {
            ct.ThrowIfCancellationRequested();
            last = await PingAsync(ct).ConfigureAwait(false);

            if (last.BootstrapError != null)
            {
                sw.Stop();
                return (false, last, sw.Elapsed);
            }
            if (last.Reachable && last.Enabled == true && last.BootstrapPending != true)
            {
                sw.Stop();
                return (true, last, sw.Elapsed);
            }

            try { await Task.Delay(pollInterval, ct).ConfigureAwait(false); }
            catch (TaskCanceledException) { break; }
        }
        sw.Stop();
        return (false, last, sw.Elapsed);
    }
}

public readonly record struct BridgePingResult(
    bool Reachable,
    double? LatencyMs,
    bool? Enabled,
    string? Map,
    bool? BootstrapPending,
    int? MaxPlayers,
    bool? SinglePlayer,
    string? BootstrapError);
