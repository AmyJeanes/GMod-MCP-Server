using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer.Models;
using Microsoft.Extensions.Logging;

namespace GModMcpServer.Bridge;

/// <summary>
/// Per-realm file-based bridge to GMod. Writes requests into <c>&lt;realm&gt;/in/</c>
/// (atomically via .tmp + rename), polls <c>&lt;realm&gt;/out/</c> for responses.
///
/// Polling rather than <c>FileSystemWatcher</c> because FSW silently drops events
/// under several conditions on Windows (buffer overflow, fast file appearance after
/// process restart, etc.). GMod is already polling at 100 ms; symmetric polling here
/// is the reliable choice.
///
/// Multi-host isolation: every request id is prefixed with this host's session GUID
/// (<c>&lt;sid&gt;__&lt;reqId&gt;</c>), so two .NET hosts sharing the same GMod
/// data dir see only their own response files. GMod treats the id as opaque and
/// echoes it back unchanged.
/// </summary>
public sealed class FileBridge : IDisposable
{
    private readonly string _realm;
    private readonly string _inDir;
    private readonly string _outDir;
    private readonly string _sessionPrefix;
    private readonly string _outGlob;
    private readonly ILogger _log;
    private readonly ConcurrentDictionary<string, TaskCompletionSource<BridgeResponse>> _pending = new();
    private readonly CancellationTokenSource _shutdown = new();
    private readonly Task _pollLoop;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = false,
    };

    public string Realm => _realm;

    public FileBridge(string mcpRoot, string realm, string sessionId, ILogger log)
    {
        _realm = realm;
        _inDir = Path.Combine(mcpRoot, realm, "in");
        _outDir = Path.Combine(mcpRoot, realm, "out");
        _sessionPrefix = sessionId + "__";
        _outGlob = _sessionPrefix + "*.json";
        _log = log;

        Directory.CreateDirectory(_inDir);
        Directory.CreateDirectory(_outDir);

        // No startup wipe: cleanup is handled centrally by GMod on init / mcp_reload,
        // and our session id is freshly generated so no prior files can collide.

        _pollLoop = Task.Run(() => PollLoopAsync(_shutdown.Token));
    }

    public async Task<BridgeResponse> SendAsync(string functionId, JsonElement args, TimeSpan timeout, CancellationToken ct)
    {
        var id = _sessionPrefix + Guid.NewGuid().ToString("N");
        var tcs = new TaskCompletionSource<BridgeResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = tcs;

        try
        {
            var req = new BridgeRequest
            {
                Id = id,
                FunctionId = functionId,
                Args = JsonNode.Parse(args.GetRawText()),
            };

            var path = Path.Combine(_inDir, id + ".json");
            var tmp = path + ".tmp";

            // Atomic write: temp file in the same dir, then move into place.
            // GMod polls *.json so the .tmp is invisible to it.
            await File.WriteAllTextAsync(tmp, JsonSerializer.Serialize(req, JsonOpts), ct).ConfigureAwait(false);
            File.Move(tmp, path, overwrite: true);

            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            using (cts.Token.Register(() => tcs.TrySetCanceled()))
            {
                return await tcs.Task.ConfigureAwait(false);
            }
        }
        finally
        {
            _pending.TryRemove(id, out _);
        }
    }

    private async Task PollLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (Directory.Exists(_outDir))
                {
                    // Glob filters by session prefix so we never see files belonging
                    // to other .NET hosts sharing the same GMod data dir.
                    foreach (var path in Directory.EnumerateFiles(_outDir, _outGlob))
                    {
                        var id = Path.GetFileNameWithoutExtension(path);
                        if (string.IsNullOrEmpty(id)) continue;

                        if (_pending.TryGetValue(id, out var tcs))
                        {
                            await TryProcessAsync(path, tcs).ConfigureAwait(false);
                        }
                        else
                        {
                            // Orphan from a timed-out request of ours — drop it.
                            try { File.Delete(path); } catch { /* best effort */ }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Poll loop error in {Realm}", _realm);
            }

            try { await Task.Delay(100, ct).ConfigureAwait(false); }
            catch (TaskCanceledException) { /* shutdown */ }
        }
    }

    private async Task TryProcessAsync(string path, TaskCompletionSource<BridgeResponse> tcs)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                var raw = await File.ReadAllTextAsync(path).ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(raw))
                {
                    await Task.Delay(10).ConfigureAwait(false);
                    continue;
                }
                var resp = JsonSerializer.Deserialize<BridgeResponse>(raw, JsonOpts);
                if (resp != null)
                {
                    try { File.Delete(path); } catch { /* best effort */ }
                    tcs.TrySetResult(resp);
                }
                return;
            }
            catch (IOException)
            {
                // File still being written — small backoff and retry.
                await Task.Delay(10).ConfigureAwait(false);
            }
            catch (JsonException ex)
            {
                _log.LogWarning(ex, "Malformed bridge response in {File}", path);
                return;
            }
        }
    }

    private void ClearOwnSession()
    {
        foreach (var dir in new[] { _inDir, _outDir })
        {
            try
            {
                if (!Directory.Exists(dir)) continue;
                foreach (var f in Directory.EnumerateFiles(dir, _outGlob))
                {
                    try { File.Delete(f); } catch { /* best effort */ }
                }
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Failed to clear session files in {Dir}", dir);
            }
        }
    }

    public void Dispose()
    {
        _shutdown.Cancel();
        try { _pollLoop.Wait(1000); } catch { /* shutting down */ }
        _shutdown.Dispose();
        ClearOwnSession();
        foreach (var kv in _pending)
        {
            kv.Value.TrySetCanceled();
        }
    }
}
