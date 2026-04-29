using GModMcpServer.Bridge;
using GModMcpServer.Tests.Helpers;
using Microsoft.Extensions.Logging.Abstractions;

namespace GModMcpServer.Tests;

public class ManifestWatcherTests
{
	private static readonly TimeSpan WatchTimeout = TimeSpan.FromSeconds(3);

	[Test]
	public async Task Reload_OnFreshManifest_LoadsMergedToolList()
	{
		using var root = new TempBridgeRoot();
		await File.WriteAllTextAsync(root.ManifestPath("server"),
			BuildManifestJson("server", "lua_run", "Run Lua."));

		using var watcher = new ManifestWatcher(root.McpRoot, NullLogger<ManifestWatcher>.Instance);

		Assert.Multiple(() =>
		{
			Assert.That(watcher.Current.Tools.ContainsKey("lua_run_sv"), Is.True);
			Assert.That(watcher.Current.Tools["lua_run_sv"].Entry.Description, Is.EqualTo("Run Lua."));
		});
	}

	[Test]
	public async Task Changed_WhenDescriptionChanges_FiresEvent()
	{
		using var root = new TempBridgeRoot();
		await File.WriteAllTextAsync(root.ManifestPath("server"),
			BuildManifestJson("server", "lua_run", "Original."));

		using var watcher = new ManifestWatcher(root.McpRoot, NullLogger<ManifestWatcher>.Instance);
		var fired = new TaskCompletionSource<MergedManifest>(TaskCreationOptions.RunContinuationsAsynchronously);
		watcher.Changed += (_, m) => fired.TrySetResult(m);

		// Mutate the description; this should trip Equals (we now compare descriptions)
		// and fire Changed.
		await File.WriteAllTextAsync(root.ManifestPath("server"),
			BuildManifestJson("server", "lua_run", "Updated."));

		var completed = await Task.WhenAny(fired.Task, Task.Delay(WatchTimeout));
		Assert.That(completed, Is.SameAs(fired.Task), "Changed event must fire within timeout for description-only edits.");
		Assert.That(fired.Task.Result.Tools["lua_run_sv"].Entry.Description, Is.EqualTo("Updated."));
	}

	[Test]
	public async Task Changed_WhenManifestRewrittenIdentically_DoesNotFireEvent()
	{
		using var root = new TempBridgeRoot();
		var content = BuildManifestJson("server", "lua_run", "Stable.");
		await File.WriteAllTextAsync(root.ManifestPath("server"), content);

		using var watcher = new ManifestWatcher(root.McpRoot, NullLogger<ManifestWatcher>.Instance);
		var fireCount = 0;
		watcher.Changed += (_, _) => Interlocked.Increment(ref fireCount);

		// Touch the file with identical content. FSW Changed will fire on disk, but
		// ManifestWatcher's content-equality check should suppress the event.
		await File.WriteAllTextAsync(root.ManifestPath("server"), content);
		await Task.Delay(500);

		Assert.That(fireCount, Is.EqualTo(0));
	}

	[Test]
	public async Task Changed_WhenManifestDeleted_FiresWithEmptyManifest()
	{
		using var root = new TempBridgeRoot();
		await File.WriteAllTextAsync(root.ManifestPath("server"),
			BuildManifestJson("server", "lua_run", "Will be deleted."));

		using var watcher = new ManifestWatcher(root.McpRoot, NullLogger<ManifestWatcher>.Instance);
		Assert.That(watcher.Current.Tools, Is.Not.Empty);

		var fired = new TaskCompletionSource<MergedManifest>(TaskCreationOptions.RunContinuationsAsynchronously);
		watcher.Changed += (_, m) => fired.TrySetResult(m);

		File.Delete(root.ManifestPath("server"));

		var completed = await Task.WhenAny(fired.Task, Task.Delay(WatchTimeout));
		Assert.That(completed, Is.SameAs(fired.Task), "Changed event must fire when manifest is deleted.");
		Assert.That(fired.Task.Result.Tools, Is.Empty);
	}

	[Test]
	public async Task Reload_BothRealms_MergesIntoSingleToolList()
	{
		using var root = new TempBridgeRoot();
		await File.WriteAllTextAsync(root.ManifestPath("server"),
			BuildManifestJson("server", "server_only", "Server tool."));
		await File.WriteAllTextAsync(root.ManifestPath("client"),
			BuildManifestJson("client", "client_only", "Client tool."));

		using var watcher = new ManifestWatcher(root.McpRoot, NullLogger<ManifestWatcher>.Instance);

		Assert.Multiple(() =>
		{
			Assert.That(watcher.Current.Tools.ContainsKey("server_only_sv"), Is.True);
			Assert.That(watcher.Current.Tools.ContainsKey("client_only_cl"), Is.True);
			Assert.That(watcher.Current.Tools["server_only_sv"].Realm, Is.EqualTo("server"));
			Assert.That(watcher.Current.Tools["client_only_cl"].Realm, Is.EqualTo("client"));
		});
	}

	private static string BuildManifestJson(string realm, string functionId, string description) =>
		$$"""
		{
		  "realm": "{{realm}}",
		  "generation": 1,
		  "functions": [
		    {
		      "id": "{{functionId}}",
		      "description": "{{description}}",
		      "schema": {"type":"object","properties":{},"required":[]},
		      "requires": [],
		      "realm": "{{realm}}"
		    }
		  ],
		  "capabilities": []
		}
		""";
}
