using System.Diagnostics;
using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using GModMcpServer.Tests.Helpers;
using Microsoft.Extensions.Logging.Abstractions;

namespace GModMcpServer.Tests;

/// <summary>
/// Tests for the dual-realm <see cref="BridgePinger.WaitUntilReadyAsync"/>: host_launch
/// and host_changelevel block until BOTH the server and client realms report ready.
/// The fail-fast cases (a terminal error on either realm) must not hang to the timeout.
/// </summary>
public class BridgeDualReadinessTests
{
    private static readonly TimeSpan FastPoll = TimeSpan.FromMilliseconds(50);

    [Test]
    public async Task WaitUntilReady_ReturnsReady_WhenBothRealmsReady()
    {
        using var root = new TempBridgeRoot();
        using var server = new FakeGmodResponder(root.McpRoot, "server", _ => ServerPing("gm_flatgrass", pending: false));
        using var client = new FakeGmodResponder(root.McpRoot, "client", _ => ClientPing(hasFocus: true));
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var (ready, srv, cli, _) = await pinger.WaitUntilReadyAsync(
            TimeSpan.FromSeconds(5), FastPoll, CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(ready, Is.True);
            Assert.That(srv.Map, Is.EqualTo("gm_flatgrass"));
            Assert.That(cli.HasFocus, Is.True);
        });
    }

    [Test]
    public async Task WaitUntilReady_WaitsForClient_WhenClientLagsBehind()
    {
        // Server is ready immediately; the client bridge comes up a tick later
        // (enabled flips false -> true). Readiness must wait for the client realm.
        using var root = new TempBridgeRoot();
        using var server = new FakeGmodResponder(root.McpRoot, "server", _ => ServerPing("gm_construct", pending: false));
        var clientPings = 0;
        using var client = new FakeGmodResponder(root.McpRoot, "client", _ =>
        {
            var n = Interlocked.Increment(ref clientPings);
            return new JsonObject { ["ok"] = true, ["enabled"] = n >= 2 };
        });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var (ready, _, _, elapsed) = await pinger.WaitUntilReadyAsync(
            TimeSpan.FromSeconds(5), FastPoll, CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(ready, Is.True);
            Assert.That(elapsed, Is.GreaterThanOrEqualTo(FastPoll), "should have waited at least one poll for the client");
        });
    }

    [Test]
    public async Task WaitUntilReady_BailsFast_OnServerBootstrapError()
    {
        using var root = new TempBridgeRoot();
        using var server = new FakeGmodResponder(root.McpRoot, "server", _ =>
            new JsonObject
            {
                ["ok"] = true,
                ["enabled"] = true,
                ["map"] = "gm_construct",
                ["bootstrap_pending"] = false,
                ["bootstrap_error"] = "target map 'nope' not found",
            });
        using var client = new FakeGmodResponder(root.McpRoot, "client", _ => ClientPing(hasFocus: false));
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var sw = Stopwatch.StartNew();
        var (ready, srv, _, _) = await pinger.WaitUntilReadyAsync(
            TimeSpan.FromSeconds(10), FastPoll, CancellationToken.None);
        sw.Stop();

        Assert.Multiple(() =>
        {
            Assert.That(ready, Is.False);
            Assert.That(srv.BootstrapError, Is.EqualTo("target map 'nope' not found"));
            Assert.That(sw.Elapsed, Is.LessThan(TimeSpan.FromSeconds(5)), "should bail well before the 10s timeout");
        });
    }

    [Test]
    public async Task WaitUntilReady_BailsFast_OnClientBootstrapError()
    {
        using var root = new TempBridgeRoot();
        using var server = new FakeGmodResponder(root.McpRoot, "server", _ => ServerPing("gm_construct", pending: false));
        using var client = new FakeGmodResponder(root.McpRoot, "client", _ =>
            new JsonObject { ["ok"] = true, ["enabled"] = true, ["bootstrap_error"] = "client boom" });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var sw = Stopwatch.StartNew();
        var (ready, _, cli, _) = await pinger.WaitUntilReadyAsync(
            TimeSpan.FromSeconds(10), FastPoll, CancellationToken.None);
        sw.Stop();

        Assert.Multiple(() =>
        {
            Assert.That(ready, Is.False);
            Assert.That(cli.BootstrapError, Is.EqualTo("client boom"));
            Assert.That(sw.Elapsed, Is.LessThan(TimeSpan.FromSeconds(5)));
        });
    }

    [Test]
    public async Task WaitUntilReady_TimesOut_WhenClientNeverReady()
    {
        using var root = new TempBridgeRoot();
        using var server = new FakeGmodResponder(root.McpRoot, "server", _ => ServerPing("gm_construct", pending: false));
        using var client = new FakeGmodResponder(root.McpRoot, "client", _ =>
            new JsonObject { ["ok"] = true, ["enabled"] = false }); // client realm never becomes enabled
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var (ready, _, _, elapsed) = await pinger.WaitUntilReadyAsync(
            TimeSpan.FromMilliseconds(400), FastPoll, CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(ready, Is.False);
            Assert.That(elapsed, Is.GreaterThanOrEqualTo(TimeSpan.FromMilliseconds(350)));
        });
    }

    private static JsonObject ServerPing(string map, bool pending) => new()
    {
        ["ok"] = true,
        ["enabled"] = true,
        ["map"] = map,
        ["bootstrap_pending"] = pending,
    };

    private static JsonObject ClientPing(bool hasFocus) => new()
    {
        ["ok"] = true,
        ["enabled"] = true,
        ["has_focus"] = hasFocus,
    };

    private static string NewSessionId() => Guid.NewGuid().ToString("N");
}
