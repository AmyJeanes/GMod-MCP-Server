using System.Text;
using GModMcpServer.Host;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Tests;

public class EngineLogReaderTests
{
    private string _path = "";

    [SetUp]
    public void SetUp() =>
        _path = Path.Combine(Path.GetTempPath(), "mcp_engine_log_" + Guid.NewGuid().ToString("N") + ".log");

    [TearDown]
    public void TearDown()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    private void Append(string s) => File.AppendAllText(_path, s, new UTF8Encoding(false));

    [Test]
    public void ReadFrom_ReturnsOnlyNewCompleteLines_AndAdvancesCursor()
    {
        Append("alpha\nbravo\n");
        var reader = new EngineLogReader(_path);
        long cursor = 0;

        Assert.That(reader.ReadFrom(ref cursor), Is.EqualTo(new[] { "alpha", "bravo" }));

        Append("charlie\n");
        Assert.That(reader.ReadFrom(ref cursor), Is.EqualTo(new[] { "charlie" }),
            "a second read returns only what was appended since the cursor");
    }

    [Test]
    public void ReadFrom_HoldsBackPartialTrailingLine_UntilItsNewlineArrives()
    {
        Append("done\npartial-no-newline");
        var reader = new EngineLogReader(_path);
        long cursor = 0;

        Assert.That(reader.ReadFrom(ref cursor), Is.EqualTo(new[] { "done" }));

        Append("-tail\n");
        Assert.That(reader.ReadFrom(ref cursor), Is.EqualTo(new[] { "partial-no-newline-tail" }));
    }

    [Test]
    public void ReadFrom_ResetsAndRereads_WhenCursorPastEndOfFile()
    {
        Append("line1\n");
        var reader = new EngineLogReader(_path);
        long cursor = 9999;

        Assert.That(reader.ReadFrom(ref cursor), Is.EqualTo(new[] { "line1" }));
        Assert.That(cursor, Is.EqualTo(new FileInfo(_path).Length));
    }

    [Test]
    public void ReadTail_ReturnsLastNLines_AndEofCursor()
    {
        for (var i = 1; i <= 10; i++) Append($"line{i}\n");
        var reader = new EngineLogReader(_path);

        var (lines, cursor) = reader.ReadTail(3);

        Assert.That(lines, Is.EqualTo(new[] { "line8", "line9", "line10" }));
        Assert.That(cursor, Is.EqualTo(new FileInfo(_path).Length));
    }
}

public class EngineLogGroupingTests
{
    [Test]
    public void Group_AttachesIndentedContinuationToHeader()
    {
        var msgs = EngineLogGrouping.Group(new[]
        {
            "Crazy origin on entity [511]", "    Origin: [1,2,3]", "    Angles: [0,0,0]", "next message",
        });

        Assert.That(msgs, Has.Count.EqualTo(2));
        Assert.That(msgs[0].Text, Does.Contain("Origin: [1,2,3]").And.Contain("Angles: [0,0,0]"));
        Assert.That(msgs[1].Header, Is.EqualTo("next message"));
    }

    [Test]
    public void Group_BlankLineEndsMessage()
    {
        var msgs = EngineLogGrouping.Group(new[] { "a", "", "b" });
        Assert.That(msgs.Select(m => m.Header), Is.EqualTo(new[] { "a", "b" }));
    }
}

public class EngineLogFilterTests
{
    [TestCase("[MCP] Bridge polling started (server).", true)]
    [TestCase("Bad SetLocalOrigin(...)", false)]
    [TestCase("[ERROR] foo", false)]
    public void IsMcpNoise(string header, bool expected) =>
        Assert.That(EngineLogFilter.IsMcpNoise(header), Is.EqualTo(expected));

    [TestCase("[ERROR] mcp_lua_run:9: boom", true)]
    [TestCase("Bad SetLocalOrigin(...)", false)]
    [TestCase("[MCP] noise", false)]
    public void IsLuaErrorLine(string header, bool expected) =>
        Assert.That(EngineLogFilter.IsLuaErrorLine(header), Is.EqualTo(expected));
}

public class EngineLogUnifyTests
{
    private static (EngineLog Log, string LogPath, string Tmp) NewLog()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "mcp_el_" + Guid.NewGuid().ToString("N"));
        var dataDir = Path.Combine(tmp, "data");
        Directory.CreateDirectory(dataDir);
        var logPath = Path.Combine(tmp, "console.log");
        File.WriteAllText(logPath, "");
        return (new EngineLog(new BridgePaths("", "", dataDir)), logPath, tmp);
    }

    [Test]
    public void Unify_EmitsConsoleLogInOrder_DropsMcpNoise()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            File.AppendAllText(p, "engine line one\n[MCP] bridge noise\nengine line two\n");

            var u = log.Unify(Array.Empty<LuaEvent>(), null);

            Assert.That(u.Select(e => e.Text), Is.EqualTo(new[] { "engine line one", "engine line two" }));
            Assert.That(u.All(e => e.Kind == "engine"), Is.True);
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void Unify_EnrichesLuaLine_WithKindAndRealm_Once()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            File.AppendAllText(p, "Zippy loaded\n"); // the same text the Lua rail reported

            var u = log.Unify(new[] { new LuaEvent("print", "Zippy loaded") }, "server");

            Assert.That(u, Has.Count.EqualTo(1), "shown once, not twice (dedup)");
            Assert.That(u[0].Kind, Is.EqualTo("print"));
            Assert.That(u[0].Realm, Is.EqualTo("server"));
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void Unify_EnrichesLuaError_ToCleanForm_DedupingTheStack()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            File.AppendAllText(p, "[ERROR] addon/foo.lua:3: boom\n  1. error - [C]:-1\n"); // raw + stack

            var u = log.Unify(new[] { new LuaEvent("error", "addon/foo.lua:3: boom") }, "server");

            Assert.That(u, Has.Count.EqualTo(1));
            Assert.That(u[0].Kind, Is.EqualTo("error"));
            Assert.That(u[0].Text, Is.EqualTo("addon/foo.lua:3: boom"), "the rail's clean message, no stack");
            Assert.That(u[0].Realm, Is.EqualTo("server"));
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void Unify_UncorrelatedLuaError_ShownRaw_TypedAsError()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            File.AppendAllText(p, "[ERROR] startup/x.lua:1: boom\n  1. stack\n");

            var u = log.Unify(Array.Empty<LuaEvent>(), null); // no rail event (startup error)

            Assert.That(u, Has.Count.EqualTo(1));
            Assert.That(u[0].Kind, Is.EqualTo("error"));
            Assert.That(u[0].Text, Does.Contain("startup/x.lua:1: boom").And.Contain("1. stack"));
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void Unify_CollapsesConsecutiveIdentical()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            for (var i = 0; i < 4; i++) File.AppendAllText(p, "Bad SetLocalOrigin(nan) on prop\n");

            var u = log.Unify(Array.Empty<LuaEvent>(), null);

            Assert.That(u, Has.Count.EqualTo(1));
            Assert.That(u[0].Count, Is.EqualTo(4));
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void Unify_WithoutAnchor_StartsAtNow()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            File.AppendAllText(p, "old line\n");
            Assert.That(log.Unify(Array.Empty<LuaEvent>(), null), Is.Empty, "start-at-now: no backlog");

            File.AppendAllText(p, "new line\n");
            Assert.That(log.Unify(Array.Empty<LuaEvent>(), null).Select(e => e.Text),
                Is.EqualTo(new[] { "new line" }));
        }
        finally { Directory.Delete(tmp, true); }
    }
}

public class EmitUnifiedEventsTests
{
    [Test]
    public void EmitUnifiedEvents_WritesJsonBlock_WithRealmAndCount_PreservingPrimary()
    {
        var result = new CallToolResult
        {
            Content = new List<ContentBlock> { new TextContentBlock { Text = "primary" } },
        };
        var events = new[]
        {
            new UnifiedEvent("print", "hello", "server", 1),
            new UnifiedEvent("engine", "Bad SetLocalOrigin", null, 3),
        };

        Program.EmitUnifiedEvents(result, events);

        var texts = result.Content!.OfType<TextContentBlock>().Select(t => t.Text).ToList();
        Assert.That(texts, Has.Some.EqualTo("primary"));
        var ev = texts.First(t => t.StartsWith("events:"));
        Assert.That(ev, Does.Contain("\"realm\":\"server\""));
        Assert.That(ev, Does.Contain("\"count\":3"));
        Assert.That(ev, Does.Contain("hello").And.Contain("Bad SetLocalOrigin"));
    }

    [Test]
    public void EmitUnifiedEvents_NoOp_WhenEmpty()
    {
        var result = new CallToolResult
        {
            Content = new List<ContentBlock> { new TextContentBlock { Text = "primary" } },
        };

        Program.EmitUnifiedEvents(result, Array.Empty<UnifiedEvent>());

        Assert.That(result.Content!, Has.Count.EqualTo(1));
    }
}
