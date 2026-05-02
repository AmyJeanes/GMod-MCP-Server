using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using GModMcpServer.Tests.Helpers;
using Microsoft.Extensions.Logging.Abstractions;

namespace GModMcpServer.Tests;

public class BridgePingerTests
{
    [Test]
    public async Task PingAsync_WhenAllFieldsPresent_DecodesAll()
    {
        using var root = new TempBridgeRoot();
        using var responder = new FakeGmodResponder(root.McpRoot, "server", req =>
        {
            Assert.That(req.FunctionId, Is.EqualTo("_ping"));
            return new JsonObject
            {
                ["ok"] = true,
                ["enabled"] = true,
                ["realm"] = "server",
                ["map"] = "gm_construct",
                ["bootstrap_pending"] = false,
            };
        });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var result = await pinger.PingAsync(CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(result.Reachable, Is.True);
            Assert.That(result.Enabled, Is.True);
            Assert.That(result.Map, Is.EqualTo("gm_construct"));
            Assert.That(result.BootstrapPending, Is.False);
            Assert.That(result.LatencyMs, Is.Not.Null);
        });
    }

    [Test]
    public async Task PingAsync_WhenBootstrapPending_PropagatesTrue()
    {
        // The whole point of this field: host_launch must keep waiting while
        // it's true, even though the bridge is reachable and mcp_enable=1.
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

        var result = await pinger.PingAsync(CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(result.Reachable, Is.True);
            Assert.That(result.BootstrapPending, Is.True);
        });
    }

    [Test]
    public async Task PingAsync_WhenOptionalFieldsMissing_ReturnsNullForThem()
    {
        // An older addon build without the bootstrap_pending / map additions
        // should still parse cleanly — the missing fields just come back null.
        using var root = new TempBridgeRoot();
        using var responder = new FakeGmodResponder(root.McpRoot, "server", _ =>
            new JsonObject { ["ok"] = true });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var result = await pinger.PingAsync(CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(result.Reachable, Is.True);
            Assert.That(result.Enabled, Is.Null);
            Assert.That(result.Map, Is.Null);
            Assert.That(result.BootstrapPending, Is.Null);
        });
    }

    [Test]
    public async Task PingAsync_WhenNoResponder_ReportsUnreachable()
    {
        using var root = new TempBridgeRoot();
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var result = await pinger.PingAsync(TimeSpan.FromMilliseconds(250), CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(result.Reachable, Is.False);
            Assert.That(result.LatencyMs, Is.Null);
            Assert.That(result.Enabled, Is.Null);
            Assert.That(result.Map, Is.Null);
            Assert.That(result.BootstrapPending, Is.Null);
        });
    }

    private static string NewSessionId() => Guid.NewGuid().ToString("N");
}
