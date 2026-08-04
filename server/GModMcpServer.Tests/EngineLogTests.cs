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

        Assert.That(reader.ReadFrom(ref cursor), Is.EqualTo(new[] { "done" }),
            "the newline-less trailing fragment is held back, not split");

        Append("-tail\n");
        Assert.That(reader.ReadFrom(ref cursor), Is.EqualTo(new[] { "partial-no-newline-tail" }),
            "once its newline arrives the whole line is delivered intact");
    }

    [Test]
    public void ReadFrom_ResetsAndRereads_WhenCursorPastEndOfFile()
    {
        Append("line1\n");
        var reader = new EngineLogReader(_path);
        long cursor = 9999; // beyond EOF => the file was rotated/shrank

        var lines = reader.ReadFrom(ref cursor);

        Assert.That(lines, Is.EqualTo(new[] { "line1" }), "resets to 0 and re-reads from the start");
        Assert.That(cursor, Is.EqualTo(new FileInfo(_path).Length));
    }

    [Test]
    public void ReadFrom_ReturnsNothing_WhenFileAbsent()
    {
        var reader = new EngineLogReader(_path); // never created
        long cursor = 50;
        Assert.That(reader.ReadFrom(ref cursor), Is.Empty);
        Assert.That(cursor, Is.EqualTo(0));
    }

    [Test]
    public void ReadTail_ReturnsLastNLines_AndEofCursor()
    {
        for (var i = 1; i <= 10; i++) Append($"line{i}\n");
        var reader = new EngineLogReader(_path);

        var (lines, cursor) = reader.ReadTail(3);

        Assert.That(lines, Is.EqualTo(new[] { "line8", "line9", "line10" }));
        Assert.That(cursor, Is.EqualTo(new FileInfo(_path).Length),
            "the returned cursor is EOF so a follow-up read continues incrementally");
    }
}

public class EngineLogGroupingTests
{
    [Test]
    public void Group_AttachesIndentedContinuationToHeader()
    {
        var lines = new[]
        {
            "Crazy origin on entity [511]",
            "    Origin: [1,2,3]",
            "    Angles: [0,0,0]",
            "next message",
        };

        var msgs = EngineLogGrouping.Group(lines);

        Assert.That(msgs, Has.Count.EqualTo(2));
        Assert.That(msgs[0].Header, Is.EqualTo("Crazy origin on entity [511]"));
        Assert.That(msgs[0].Text, Does.Contain("Origin: [1,2,3]").And.Contain("Angles: [0,0,0]"));
        Assert.That(msgs[1].Header, Is.EqualTo("next message"));
    }

    [Test]
    public void Group_BlankLineEndsMessage()
    {
        var msgs = EngineLogGrouping.Group(new[] { "a", "", "b" });
        Assert.That(msgs.Select(m => m.Header), Is.EqualTo(new[] { "a", "b" }));
    }

    [Test]
    public void Group_SingleLinesAreSeparateMessages()
    {
        var msgs = EngineLogGrouping.Group(new[] { "one", "two", "three" });
        Assert.That(msgs, Has.Count.EqualTo(3));
    }
}

public class EngineLogClassifyTests
{
    [TestCase("Bad SetLocalOrigin(-nan,-nan,-nan) on prop", EngineLineClass.Warning)]
    [TestCase("Crazy origin on entity [511]", EngineLineClass.Warning)]
    [TestCase("prop:SetPos(...): Ignoring unreasonable position.", EngineLineClass.Warning)]
    [TestCase("[ERROR] mcp_lua_run:9: boom", EngineLineClass.LuaError)]
    [TestCase("[MCP] lua-error capture active", EngineLineClass.Marker)]
    [TestCase("[MCP] Bridge polling started (server).", EngineLineClass.McpNoise)]
    [TestCase("Requesting texture value from var \"$basetexture\"", EngineLineClass.Benign)]
    [TestCase("KeyValues Error: RecursiveLoadFromBuffer", EngineLineClass.Benign)]
    [TestCase("Some novel Warning nobody allowlisted", EngineLineClass.Notable)]
    [TestCase("Zippy's library loaded!", EngineLineClass.Benign)]
    [TestCase("", EngineLineClass.Benign)]
    public void Classify(string header, EngineLineClass expected) =>
        Assert.That(EngineLogFilter.Classify(header), Is.EqualTo(expected));
}

public class EngineLogPassiveTests
{
    private static (EngineLog Log, string LogPath, string Tmp) NewLog()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "mcp_el_" + Guid.NewGuid().ToString("N"));
        var dataDir = Path.Combine(tmp, "data");
        Directory.CreateDirectory(dataDir);
        var logPath = Path.Combine(tmp, "console.log");
        File.WriteAllText(logPath, ""); // exists, empty
        return (new EngineLog(new BridgePaths("", "", dataDir)), logPath, tmp);
    }

    [Test]
    public void DrainPassive_SurfacesStartupErrorsBeforeMarker_ExcludesAfter()
    {
        var (log, logPath, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch(); // anchor at 0, capture inactive
            File.AppendAllText(logPath,
                "[ERROR] addon/foo.lua:3: startup boom\n" + // pre-marker: surface
                "[MCP] lua-error capture active\n" +         // the seam
                "[ERROR] addon/bar.lua:9: later boom\n");    // post-marker: exclude

            var r = log.DrainPassive();

            Assert.That(r.Highlights, Has.Count.EqualTo(1));
            Assert.That(r.Highlights[0].StartupError, Is.True);
            Assert.That(r.Highlights[0].Text, Does.Contain("startup boom"));
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void DrainPassive_CollapsesConsecutiveIdenticalWarnings()
    {
        var (log, logPath, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            for (var i = 0; i < 5; i++) File.AppendAllText(logPath, "Bad SetLocalOrigin(nan) on prop\n");

            var r = log.DrainPassive();

            Assert.That(r.Highlights, Has.Count.EqualTo(1));
            Assert.That(r.Highlights[0].Count, Is.EqualTo(5), "the console's (xN) collapse, recreated");
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void DrainPassive_GroupsMultiLineWarningWithItsDetail()
    {
        var (log, logPath, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            File.AppendAllText(logPath,
                "Crazy origin on entity [511]\n    Origin: [1,2,3]\n    Angles: [0,0,0]\n");

            var r = log.DrainPassive();

            Assert.That(r.Highlights, Has.Count.EqualTo(1));
            Assert.That(r.Highlights[0].Text, Does.Contain("Origin: [1,2,3]"),
                "the indented detail rides with the matched header");
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void DrainPassive_CountsNotableButDoesNotInline()
    {
        var (log, logPath, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            File.AppendAllText(logPath,
                "Some novel Warning nobody allowlisted\nRequesting texture value blah\n");

            var r = log.DrainPassive();

            Assert.That(r.Highlights, Is.Empty);
            Assert.That(r.OtherNotableCount, Is.EqualTo(1), "the Warning counts; the texture line is benign");
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void DrainPassive_WithoutAnchor_StartsAtNow_NoBacklog()
    {
        var (log, logPath, tmp) = NewLog();
        try
        {
            File.AppendAllText(logPath, "Crazy origin on entity [7]\n"); // pre-existing history

            // No AnchorAtLaunch (game started externally): first drain starts at now.
            Assert.That(log.DrainPassive().IsEmpty, Is.True);

            File.AppendAllText(logPath, "Bad SetLocalOrigin(1,2,3) on foo\n");
            var r = log.DrainPassive();
            Assert.That(r.Highlights, Has.Count.EqualTo(1));
            Assert.That(r.Highlights[0].Text, Does.Contain("Bad SetLocalOrigin(1,2,3)"));
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void DrainPassive_WithoutAnchor_TreatsLaterErrorsAsLuaRailCovered_NotStartup()
    {
        var (log, logPath, tmp) = NewLog();
        try
        {
            // Attaching to an already-running game (no anchor): the capture marker is
            // behind the start-at-now cursor, so a later [ERROR] must NOT be mistaken for
            // a startup error the Lua rail didn't see — it did.
            log.DrainPassive();
            File.AppendAllText(logPath, "[ERROR] addon/x.lua:1: boom\n");

            Assert.That(log.DrainPassive().Highlights, Is.Empty,
                "a post-attach [ERROR] is owned by the Lua rail, not surfaced as a startup error");
        }
        finally { Directory.Delete(tmp, true); }
    }
}

public class AppendEngineEventsTests
{
    [Test]
    public void AppendEngineEvents_InlinesHighlightsWithCount_AndBreadcrumb()
    {
        var result = new CallToolResult
        {
            Content = new List<ContentBlock> { new TextContentBlock { Text = "primary" } },
        };
        var passive = new PassiveEngineResult(
            new[] { new EngineHighlight("Bad SetLocalOrigin(nan) on prop", 5, false) }, 3);

        Program.AppendEngineEvents(result, passive);

        var texts = result.Content!.OfType<TextContentBlock>().Select(t => t.Text).ToList();
        Assert.That(texts, Has.Some.EqualTo("primary"), "the primary result block survives");
        var ev = texts.First(t => t.StartsWith("engine_events"));
        Assert.That(ev, Does.Contain("Bad SetLocalOrigin"));
        Assert.That(ev, Does.Contain("\"count\":5"));
        Assert.That(ev, Does.Contain("+3 notable"));
    }

    [Test]
    public void AppendEngineEvents_TagsStartupErrorKind()
    {
        var result = new CallToolResult { Content = new List<ContentBlock>() };
        var passive = new PassiveEngineResult(new[] { new EngineHighlight("[ERROR] foo", 1, true) }, 0);

        Program.AppendEngineEvents(result, passive);

        var ev = result.Content!.OfType<TextContentBlock>().First().Text;
        Assert.That(ev, Does.Contain("engine_startup_error"));
    }

    [Test]
    public void AppendEngineEvents_NoOp_WhenEmpty()
    {
        var result = new CallToolResult
        {
            Content = new List<ContentBlock> { new TextContentBlock { Text = "primary" } },
        };

        Program.AppendEngineEvents(result, PassiveEngineResult.Empty);

        Assert.That(result.Content!, Has.Count.EqualTo(1));
    }
}
