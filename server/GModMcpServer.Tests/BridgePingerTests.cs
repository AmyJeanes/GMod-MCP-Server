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
                ["maxplayers"] = 16,
                ["singleplayer"] = false,
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
            Assert.That(result.MaxPlayers, Is.EqualTo(16));
            Assert.That(result.SinglePlayer, Is.False);
            Assert.That(result.BootstrapPending, Is.False);
            Assert.That(result.LatencyMs, Is.Not.Null);
        });
    }

    [Test]
    public async Task PingAsync_WhenMaxplayersIsWholeDouble_TruncatesToInt()
    {
        // Lua numbers are doubles; depending on the JSON encoder a whole value
        // can arrive as 2.0 rather than 2. The pinger must still decode it.
        using var root = new TempBridgeRoot();
        using var responder = new FakeGmodResponder(root.McpRoot, "server", _ =>
            new JsonObject
            {
                ["ok"] = true,
                ["maxplayers"] = 2.0,
                ["singleplayer"] = false,
            });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var result = await pinger.PingAsync(CancellationToken.None);

        Assert.That(result.MaxPlayers, Is.EqualTo(2));
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
    public async Task PingAsync_WhenBootstrapError_DecodesString()
    {
        // A terminal launch/level failure (e.g. a missing map) rides back on _ping
        // so the host can fail fast instead of waiting out the timeout.
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

        var result = await pinger.PingAsync(CancellationToken.None);

        Assert.That(result.BootstrapError, Is.EqualTo("target map 'nope' not found"));
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
            Assert.That(result.MaxPlayers, Is.Null);
            Assert.That(result.SinglePlayer, Is.Null);
            Assert.That(result.BootstrapPending, Is.Null);
            Assert.That(result.BootstrapError, Is.Null);
            Assert.That(result.HasFocus, Is.Null);
            Assert.That(result.Capabilities, Is.Null);
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

    [Test]
    public async Task PingAsync_DecodesHasFocus_True()
    {
        using var root = new TempBridgeRoot();
        using var responder = new FakeGmodResponder(root.McpRoot, "server", _ =>
            new JsonObject { ["ok"] = true, ["has_focus"] = true });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var result = await pinger.PingAsync(CancellationToken.None);

        Assert.That(result.HasFocus, Is.True);
    }

    [Test]
    public async Task PingAsync_DecodesHasFocus_False()
    {
        // Regression guard: a genuine false must survive as false, not collapse to
        // null. The Lua side must not use the `and`/`or` idiom that drops false.
        using var root = new TempBridgeRoot();
        using var responder = new FakeGmodResponder(root.McpRoot, "server", _ =>
            new JsonObject { ["ok"] = true, ["has_focus"] = false });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var result = await pinger.PingAsync(CancellationToken.None);

        Assert.That(result.HasFocus, Is.False);
    }

    [Test]
    public async Task PingAsync_DecodesCapabilities()
    {
        using var root = new TempBridgeRoot();
        using var responder = new FakeGmodResponder(root.McpRoot, "server", _ =>
            new JsonObject
            {
                ["ok"] = true,
                ["capabilities"] = new JsonObject { ["unsafe"] = true, ["world_control"] = false },
            });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var result = await pinger.PingAsync(CancellationToken.None);

        Assert.That(result.Capabilities, Is.Not.Null);
        Assert.Multiple(() =>
        {
            Assert.That(result.Capabilities!["unsafe"], Is.True);
            Assert.That(result.Capabilities!["world_control"], Is.False);
        });
    }

    [Test]
    public async Task PingAsync_ClientRealm_RoutesToClientResponder()
    {
        // Only a CLIENT responder exists. The realm-targeted ping must reach it, and
        // the default (server) ping must NOT — proving the realm parameter routes.
        using var root = new TempBridgeRoot();
        using var clientResponder = new FakeGmodResponder(root.McpRoot, "client", req =>
        {
            Assert.That(req.FunctionId, Is.EqualTo("_ping"));
            return new JsonObject { ["ok"] = true, ["enabled"] = true, ["realm"] = "client", ["has_focus"] = true };
        });
        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var pinger = new BridgePinger(registry);

        var client = await pinger.PingAsync("client", TimeSpan.FromSeconds(2), CancellationToken.None);
        var server = await pinger.PingAsync(TimeSpan.FromMilliseconds(250), CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(client.Reachable, Is.True);
            Assert.That(client.HasFocus, Is.True);
            Assert.That(server.Reachable, Is.False, "the default ping targets the server realm, which has no responder here");
        });
    }

    private static string NewSessionId() => Guid.NewGuid().ToString("N");
}
