using System.Text.Json;
using System.Text.Json.Nodes;
using GModMcpServer;
using GModMcpServer.Bridge;
using GModMcpServer.Host.Tools;
using GModMcpServer.Tests.Helpers;
using Microsoft.Extensions.Logging.Abstractions;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Tests;

/// <summary>
/// host_changelevel flow tests. A server fake responder branches on the function
/// id (_ping vs _changelevel) over mutable state, so we can drive the whole
/// pre-check → trigger → readiness-wait sequence without a real GMod. The readiness
/// wait is dual-realm, so each test also stands up a ready client responder.
/// </summary>
public class ChangeLevelToolTests
{
    [Test]
    public async Task Invoke_HappyPath_ReturnsReady()
    {
        using var root = new TempBridgeRoot();
        var changed = false;
        var pingsAfterChange = 0;
        using var responder = new FakeGmodResponder(root.McpRoot, "server", req =>
        {
            if (req.FunctionId == "_changelevel")
            {
                changed = true;
                return new JsonObject { ["ok"] = true, ["map"] = "gm_flatgrass" };
            }
            var pending = false;
            if (changed) { pingsAfterChange++; pending = pingsAfterChange < 2; }
            return Ping("gm_flatgrass", pending);
        });
        using var clientResponder = new FakeGmodResponder(root.McpRoot, "client", _ => ClientReady());

        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var tool = NewTool(root, registry);

        var res = await tool.InvokeAsync(Args("""{"map":"gm_flatgrass","wait_timeout_seconds":5}"""), CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(res.IsError, Is.False);
            Assert.That(ResultText(res), Does.Contain("gm_flatgrass"));
        });
    }

    [Test]
    public async Task Invoke_SameMapReload_ReturnsReady()
    {
        // Map name never changes — readiness must come from the bootstrap_pending
        // flip, not from observing a different map.
        using var root = new TempBridgeRoot();
        var changed = false;
        var pingsAfterChange = 0;
        using var responder = new FakeGmodResponder(root.McpRoot, "server", req =>
        {
            if (req.FunctionId == "_changelevel")
            {
                changed = true;
                return new JsonObject { ["ok"] = true, ["map"] = "gm_construct" };
            }
            var pending = false;
            if (changed) { pingsAfterChange++; pending = pingsAfterChange < 2; }
            return Ping("gm_construct", pending);
        });
        using var clientResponder = new FakeGmodResponder(root.McpRoot, "client", _ => ClientReady());

        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var tool = NewTool(root, registry);

        var res = await tool.InvokeAsync(Args("""{"map":"gm_construct","wait_timeout_seconds":5}"""), CancellationToken.None);

        Assert.That(res.IsError, Is.False);
    }

    [Test]
    public async Task Invoke_WhenTriggerRejected_ReturnsErrorImmediately()
    {
        using var root = new TempBridgeRoot();
        var pingCount = 0;
        using var responder = new FakeGmodResponder(root.McpRoot, "server", req =>
        {
            if (req.FunctionId == "_changelevel")
            {
                return new JsonObject { ["ok"] = false, ["error"] = "map 'nope' not found (no maps/nope.bsp)" };
            }
            Interlocked.Increment(ref pingCount);
            return Ping("gm_construct", pending: false);
        });
        using var clientResponder = new FakeGmodResponder(root.McpRoot, "client", _ => ClientReady());

        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var tool = NewTool(root, registry);

        var res = await tool.InvokeAsync(Args("""{"map":"nope","wait_timeout_seconds":5}"""), CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(res.IsError, Is.True);
            Assert.That(ResultText(res), Does.Contain("not found"));
            // Only the pre-check ping (server realm) should have run — no readiness polling.
            Assert.That(pingCount, Is.EqualTo(1));
        });
    }

    [Test]
    public async Task Invoke_OnTimeout_DeletesMarker()
    {
        using var root = new TempBridgeRoot();
        var marker = Path.Combine(root.McpRoot, "level_change.json");
        var changed = false;
        using var responder = new FakeGmodResponder(root.McpRoot, "server", req =>
        {
            if (req.FunctionId == "_changelevel")
            {
                changed = true;
                File.WriteAllText(marker, """{"target_map":"gm_flatgrass"}"""); // mimic RequestLevelChange
                return new JsonObject { ["ok"] = true, ["map"] = "gm_flatgrass" };
            }
            // false on the pre-check ping, true forever after → never ready → timeout.
            return Ping("gm_construct", pending: changed);
        });
        using var clientResponder = new FakeGmodResponder(root.McpRoot, "client", _ => ClientReady());

        using var registry = new FileBridgeRegistry(root.McpRoot, NewSessionId(), NullLoggerFactory.Instance);
        var tool = NewTool(root, registry);

        var res = await tool.InvokeAsync(Args("""{"map":"gm_flatgrass","wait_timeout_seconds":1}"""), CancellationToken.None);

        Assert.Multiple(() =>
        {
            Assert.That(res.IsError, Is.True);
            Assert.That(File.Exists(marker), Is.False, "the stale marker should be cleaned up on timeout");
        });
    }

    private static JsonObject Ping(string map, bool pending) => new()
    {
        ["ok"] = true,
        ["enabled"] = true,
        ["map"] = map,
        ["bootstrap_pending"] = pending,
    };

    // Client realm: ready (reachable + enabled) so the dual-realm wait isn't blocked
    // on it; client carries no bootstrap state.
    private static JsonObject ClientReady() => new()
    {
        ["ok"] = true,
        ["enabled"] = true,
    };

    private static ChangeLevelTool NewTool(TempBridgeRoot root, FileBridgeRegistry registry)
    {
        var pinger = new BridgePinger(registry);
        var paths = new BridgePaths(root.McpRoot, NewSessionId(), root.McpRoot);
        return new ChangeLevelTool(pinger, registry, paths);
    }

    private static Dictionary<string, JsonElement> Args(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var dict = new Dictionary<string, JsonElement>();
        foreach (var p in doc.RootElement.EnumerateObject())
        {
            dict[p.Name] = p.Value.Clone();
        }
        return dict;
    }

    private static string ResultText(CallToolResult res) =>
        (res.Content?.FirstOrDefault() as TextContentBlock)?.Text ?? "";

    private static string NewSessionId() => Guid.NewGuid().ToString("N");
}
