using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer.Models;

namespace GModMcpServer.Tests.Helpers;

/// <summary>
/// Stand-in for the GMod side of the bridge: polls <c>&lt;realm&gt;/in/*.json</c> on a
/// temp filesystem and writes responses to <c>&lt;realm&gt;/out/&lt;id&gt;.json</c> via the
/// supplied dispatch delegate. Mirrors the real Lua bridge closely enough for round-trip
/// tests of <see cref="GModMcpServer.Bridge.FileBridge"/>.
/// </summary>
internal sealed class FakeGmodResponder : IDisposable
{
	private readonly string _inDir;
	private readonly string _outDir;
	private readonly Func<BridgeRequest, JsonNode?> _dispatch;
	private readonly CancellationTokenSource _cts = new();
	private readonly Task _loop;

	public int ProcessedCount;

	public FakeGmodResponder(string mcpRoot, string realm, Func<BridgeRequest, JsonNode?> dispatch)
	{
		_inDir = Path.Combine(mcpRoot, realm, "in");
		_outDir = Path.Combine(mcpRoot, realm, "out");
		_dispatch = dispatch;
		Directory.CreateDirectory(_inDir);
		Directory.CreateDirectory(_outDir);
		_loop = Task.Run(() => PollLoopAsync(_cts.Token));
	}

	private async Task PollLoopAsync(CancellationToken ct)
	{
		while (!ct.IsCancellationRequested)
		{
			try
			{
				if (Directory.Exists(_inDir))
				{
					foreach (var path in Directory.EnumerateFiles(_inDir, "*.json"))
					{
						await ProcessOneAsync(path).ConfigureAwait(false);
					}
				}
			}
			catch
			{
				// swallow — best-effort like the real Lua side
			}

			try { await Task.Delay(20, ct).ConfigureAwait(false); }
			catch (TaskCanceledException) { return; }
		}
	}

	private async Task ProcessOneAsync(string path)
	{
		string raw;
		try { raw = await File.ReadAllTextAsync(path).ConfigureAwait(false); }
		catch (IOException) { return; }

		try { File.Delete(path); } catch { /* best effort */ }

		if (string.IsNullOrWhiteSpace(raw)) return;

		BridgeRequest? req;
		try { req = JsonSerializer.Deserialize<BridgeRequest>(raw); }
		catch { return; }
		if (req is null || string.IsNullOrEmpty(req.Id)) return;

		var result = _dispatch(req);

		var response = new JsonObject
		{
			["id"] = req.Id,
			["result"] = result,
		};

		var outPath = Path.Combine(_outDir, req.Id + ".json");
		await File.WriteAllTextAsync(outPath, response.ToJsonString()).ConfigureAwait(false);

		Interlocked.Increment(ref ProcessedCount);
	}

	public void Dispose()
	{
		_cts.Cancel();
		try { _loop.Wait(2000); } catch { /* shutdown */ }
		_cts.Dispose();
	}
}
