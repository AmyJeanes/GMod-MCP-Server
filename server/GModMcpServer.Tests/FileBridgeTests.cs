using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using GModMcpServer.Tests.Helpers;
using Microsoft.Extensions.Logging.Abstractions;

namespace GModMcpServer.Tests;

public class FileBridgeTests
{
	private static readonly TimeSpan ShortTimeout = TimeSpan.FromSeconds(2);
	private static readonly JsonElement EmptyArgs = JsonDocument.Parse("{}").RootElement;

	[Test]
	public async Task Send_WhenResponderEchoes_ReturnsResponse()
	{
		using var root = new TempBridgeRoot();
		using var responder = new FakeGmodResponder(root.McpRoot, "server",
			req => new JsonObject { ["ok"] = true, ["result"] = "echoed" });

		using var bridge = new FileBridge(root.McpRoot, "server", NewSessionId(), NullLogger.Instance);

		var resp = await bridge.SendAsync("noop", EmptyArgs, ShortTimeout, CancellationToken.None);

		Assert.That(resp.Result, Is.Not.Null);
		var ok = resp.Result!.AsObject()["ok"]!.GetValue<bool>();
		var result = resp.Result!.AsObject()["result"]!.GetValue<string>();
		Assert.Multiple(() =>
		{
			Assert.That(ok, Is.True);
			Assert.That(result, Is.EqualTo("echoed"));
		});
	}

	[Test]
	public void Send_WhenNoResponder_TimesOut()
	{
		using var root = new TempBridgeRoot();
		using var bridge = new FileBridge(root.McpRoot, "server", NewSessionId(), NullLogger.Instance);

		Assert.That(async () =>
			await bridge.SendAsync("noop", EmptyArgs, TimeSpan.FromMilliseconds(250), CancellationToken.None),
			Throws.InstanceOf<TaskCanceledException>());
	}

	[Test]
	public async Task Send_PrefixesIdWithSessionGuid()
	{
		using var root = new TempBridgeRoot();
		var sessionId = NewSessionId();
		string? capturedId = null;

		using var responder = new FakeGmodResponder(root.McpRoot, "server",
			req => { capturedId = req.Id; return new JsonObject { ["ok"] = true }; });
		using var bridge = new FileBridge(root.McpRoot, "server", sessionId, NullLogger.Instance);

		await bridge.SendAsync("noop", EmptyArgs, ShortTimeout, CancellationToken.None);

		Assert.That(capturedId, Does.StartWith(sessionId + "__"));
		Assert.That(capturedId!.Length, Is.GreaterThan(sessionId.Length + 2));
	}

	[Test]
	public async Task Send_TwoBridgesShareDirWithoutCollision()
	{
		using var root = new TempBridgeRoot();
		var captured = new List<string>();
		var lockObj = new object();

		using var responder = new FakeGmodResponder(root.McpRoot, "server",
			req =>
			{
				lock (lockObj) captured.Add(req.Id);
				return new JsonObject { ["ok"] = true, ["from"] = req.Id };
			});

		var sidA = NewSessionId();
		var sidB = NewSessionId();
		using var bridgeA = new FileBridge(root.McpRoot, "server", sidA, NullLogger.Instance);
		using var bridgeB = new FileBridge(root.McpRoot, "server", sidB, NullLogger.Instance);

		var taskA = bridgeA.SendAsync("noop", EmptyArgs, ShortTimeout, CancellationToken.None);
		var taskB = bridgeB.SendAsync("noop", EmptyArgs, ShortTimeout, CancellationToken.None);

		await Task.WhenAll(taskA, taskB);

		var idA = taskA.Result.Result!.AsObject()["from"]!.GetValue<string>();
		var idB = taskB.Result.Result!.AsObject()["from"]!.GetValue<string>();

		Assert.Multiple(() =>
		{
			Assert.That(idA, Does.StartWith(sidA + "__"));
			Assert.That(idB, Does.StartWith(sidB + "__"));
			Assert.That(captured.Count, Is.EqualTo(2));
		});
	}

	[Test]
	public async Task Send_ResponseFromAnotherSession_NotConsumed()
	{
		using var root = new TempBridgeRoot();
		var ourSession = NewSessionId();
		var foreignSession = NewSessionId();

		// Plant a foreign response file BEFORE the bridge starts.
		var foreignId = foreignSession + "__" + Guid.NewGuid().ToString("N");
		var foreignPath = Path.Combine(root.OutDir("server"), foreignId + ".json");
		await File.WriteAllTextAsync(foreignPath,
			"""{"id":"_ignored","result":{"ok":true}}""");

		using var bridge = new FileBridge(root.McpRoot, "server", ourSession, NullLogger.Instance);
		// Let the poll loop tick a few times so any consume-attempt would have happened.
		await Task.Delay(300);

		Assert.That(File.Exists(foreignPath), Is.True,
			"FileBridge must not touch responses belonging to another session.");
	}

	[Test]
	public async Task Dispose_DeletesOwnSessionFiles_LeavesOthersUntouched()
	{
		using var root = new TempBridgeRoot();
		var ourSession = NewSessionId();
		var foreignSession = NewSessionId();

		// Plant one of our orphans and one foreign file in both in/ and out/.
		var ourOrphan = Path.Combine(root.OutDir("server"),
			ourSession + "__" + Guid.NewGuid().ToString("N") + ".json");
		var foreignOrphan = Path.Combine(root.OutDir("server"),
			foreignSession + "__" + Guid.NewGuid().ToString("N") + ".json");

		await File.WriteAllTextAsync(ourOrphan, """{"id":"x","result":{"ok":true}}""");
		await File.WriteAllTextAsync(foreignOrphan, """{"id":"y","result":{"ok":true}}""");

		var bridge = new FileBridge(root.McpRoot, "server", ourSession, NullLogger.Instance);

		// Give the poll loop a moment to potentially eat ourOrphan as a "no _pending match"
		// orphan-cleanup; even if it does, the foreign file must remain untouched.
		await Task.Delay(200);
		bridge.Dispose();

		Assert.That(File.Exists(foreignOrphan), Is.True,
			"Dispose must only delete files matching this session's prefix.");
	}

	private static string NewSessionId() => Guid.NewGuid().ToString("N");
}
