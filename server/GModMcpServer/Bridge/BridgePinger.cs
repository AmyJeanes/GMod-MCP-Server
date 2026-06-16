using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace GModMcpServer.Bridge;

/// <summary>
/// Single source of truth for sending <c>_ping</c> to GMod and decoding the
/// reply. Used by <c>host_status</c> for one-shot diagnostics and by
/// <c>host_launch</c> / <c>host_changelevel</c> for the readiness wait. Pings target
/// the <c>"server"</c> realm by default; the focus-reconcile path also pings the
/// <c>"client"</c> realm — the only realm where <c>system.HasFocus()</c> exists.
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
        => PingAsync("server", DefaultTimeout, ct);

    public Task<BridgePingResult> PingAsync(TimeSpan timeout, CancellationToken ct)
        => PingAsync("server", timeout, ct);

    public async Task<BridgePingResult> PingAsync(string realm, TimeSpan timeout, CancellationToken ct)
    {
        try
        {
            var bridge = _bridges.Get(realm);
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
            bool? hasFocus = null;
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

                // Client realm only (server omits it); absent on older addons → null.
                // Decoded explicitly so a genuine false is preserved (not treated as absent).
                if (obj.TryGetPropertyValue("has_focus", out var hfNode)
                    && hfNode is JsonValue hfVal
                    && hfVal.TryGetValue<bool>(out var hfBool))
                {
                    hasFocus = hfBool;
                }
            }

            return new BridgePingResult(true, sw.Elapsed.TotalMilliseconds, enabled, map, bootstrapPending, maxPlayers, singlePlayer, bootstrapError, hasFocus);
        }
        catch (TaskCanceledException)
        {
            return new BridgePingResult(false, null, null, null, null, null, null, null, null);
        }
        catch (Exception)
        {
            return new BridgePingResult(false, null, null, null, null, null, null, null, null);
        }
    }

    /// <summary>
    /// Polls <c>_ping</c> on BOTH realms until both are ready — reachable,
    /// <c>mcp_enable</c> on, and no launch/level transition pending — or
    /// <paramref name="timeout"/> elapses. Bails early with <c>Ready = false</c> if
    /// either realm reports a terminal <c>bootstrap_error</c>; that's checked
    /// <em>before</em> the ready condition because the failure path also clears
    /// <c>bootstrap_pending</c>, so the naive ready check would otherwise treat a
    /// failed transition as success. The client realm only carries meaningful
    /// <c>reachable</c>/<c>enabled</c> (bootstrap state is server-side), so the shared
    /// predicate handles both. Shared by <c>host_launch</c> and <c>host_changelevel</c>.
    /// </summary>
    public async Task<(bool Ready, BridgePingResult Server, BridgePingResult Client, TimeSpan Elapsed)> WaitUntilReadyAsync(
        TimeSpan timeout, TimeSpan pollInterval, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        var server = default(BridgePingResult);
        var client = default(BridgePingResult);
        while (sw.Elapsed < timeout)
        {
            ct.ThrowIfCancellationRequested();
            server = await PingAsync("server", DefaultTimeout, ct).ConfigureAwait(false);
            client = await PingAsync("client", DefaultTimeout, ct).ConfigureAwait(false);

            if (server.BootstrapError != null || client.BootstrapError != null)
            {
                sw.Stop();
                return (false, server, client, sw.Elapsed);
            }
            if (IsReady(server) && IsReady(client))
            {
                sw.Stop();
                return (true, server, client, sw.Elapsed);
            }

            try { await Task.Delay(pollInterval, ct).ConfigureAwait(false); }
            catch (TaskCanceledException) { break; }
        }
        sw.Stop();
        return (false, server, client, sw.Elapsed);
    }

    private static bool IsReady(in BridgePingResult p) =>
        p.Reachable && p.Enabled == true && p.BootstrapPending != true;
}

public readonly record struct BridgePingResult(
    bool Reachable,
    double? LatencyMs,
    bool? Enabled,
    string? Map,
    bool? BootstrapPending,
    int? MaxPlayers,
    bool? SinglePlayer,
    string? BootstrapError,
    bool? HasFocus);
