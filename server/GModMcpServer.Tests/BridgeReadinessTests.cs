using System.Diagnostics;
using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using GModMcpServer.Tests.Helpers;
using Microsoft.Extensions.Logging.Abstractions;

namespace GModMcpServer.Tests;

/// <summary>
/// Tests for <see cref="BridgePinger.WaitUntilReadyAsync"/>, the readiness wait
/// shared by host_launch and host_changelevel. The fail-fast case is the one that
/// matters most: a bad target map must not hang the host until its timeout.
/// </summary>
public class BridgeReadinessTests
{
    private static readonly TimeSpan FastPoll = TimeSpan.FromMilliseconds(50);

    [Test]
    public async Task WaitUntilReady_ReturnsReady_WhenPendingClears()
    {
        using var root = new TempBridgeRoot();
        var pings = 0;
        using var responder = new FakeGmodResponder(root.McpRoot, "server", _ =>
        {
            var n = Interlocked.Increment(ref pings);
            return new JsonObject
            {
                ["ok"] = true,
                ["enabled"] = true,
                ["map"] = "gm_flatgrass",
                ["bootstrap_pending"] = n < 2, // pending on the first ping, then ready
            };
        });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var (ready, last, _) = await pinger.WaitUntilReadyAsync(
            TimeSpan.FromSeconds(5), FastPoll, CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(ready, Is.True);
            Assert.That(last.Map, Is.EqualTo("gm_flatgrass"));
        });
    }

    [Test]
    public async Task WaitUntilReady_BailsFast_OnBootstrapError()
    {
        // bootstrap_pending is false here, which would otherwise satisfy the ready
        // condition — the bootstrap_error check must take precedence and bail.
        using var root = new TempBridgeRoot();
        using var responder = new FakeGmodResponder(root.McpRoot, "server", _ =>
            new JsonObject
            {
                ["ok"] = true,
                ["enabled"] = true,
                ["map"] = "gm_construct",
                ["bootstrap_pending"] = false,
                ["bootstrap_error"] = "target map 'nope' not found",
            });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var sw = Stopwatch.StartNew();
        var (ready, last, _) = await pinger.WaitUntilReadyAsync(
            TimeSpan.FromSeconds(10), FastPoll, CancellationToken.None);
        sw.Stop();

        Assert.Multiple(() =>
        {
            Assert.That(ready, Is.False);
            Assert.That(last.BootstrapError, Is.EqualTo("target map 'nope' not found"));
            Assert.That(sw.Elapsed, Is.LessThan(TimeSpan.FromSeconds(5)),
                "should bail well before the 10s timeout");
        });
    }

    [Test]
    public async Task WaitUntilReady_TimesOut_WhenPendingNeverClears()
    {
        using var root = new TempBridgeRoot();
        using var responder = new FakeGmodResponder(root.McpRoot, "server", _ =>
            new JsonObject
            {
                ["ok"] = true,
                ["enabled"] = true,
                ["map"] = "gm_construct",
                ["bootstrap_pending"] = true,
            });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var (ready, _, elapsed) = await pinger.WaitUntilReadyAsync(
            TimeSpan.FromMilliseconds(400), FastPoll, CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(ready, Is.False);
            Assert.That(elapsed, Is.GreaterThanOrEqualTo(TimeSpan.FromMilliseconds(350)));
        });
    }

    private static string NewSessionId() => Guid.NewGuid().ToString("N");
}
