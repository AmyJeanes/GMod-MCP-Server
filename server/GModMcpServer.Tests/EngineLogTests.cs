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
        Assert.That(reader.ReadFrom(ref cursor), Is.EqualTo(new[] { "charlie" }));
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

    // Runtime errors are [ERROR]-prefixed; addon load errors are [<addon>]-prefixed but carry a
    // numbered stack. Plain engine lines and the indented (non-numbered) Crazy-origin block don't.
    [TestCase("[ERROR] mcp_lua_run:9: boom", "[ERROR] mcp_lua_run:9: boom", true)]
    [TestCase("[aaa] x.lua:4: boom", "[aaa] x.lua:4: boom\n   2. unknown - x.lua:4", true)]
    [TestCase("Bad SetLocalOrigin(...)", "Bad SetLocalOrigin(...)", false)]
    [TestCase("Crazy origin [5]", "Crazy origin [5]\n    Origin: [1,2,3]\n    Angles: [0,0,0]", false)]
    [TestCase("[SomeAddon] loaded ok", "[SomeAddon] loaded ok", false)]
    public void IsLuaError(string header, string text, bool expected) =>
        Assert.That(EngineLogFilter.IsLuaError(header, text), Is.EqualTo(expected));

    [TestCase("---- Host_Changelevel ----", true)]
    [TestCase("Dropped Divided (76561198) from server (Server shutting down)", true)]
    [TestCase("Bad SetLocalOrigin(...)", false)]
    [TestCase("[MCP] Bridge polling started (server).", false)]
    public void IsMapChange(string line, bool expected) =>
        Assert.That(EngineLogFilter.IsMapChange(line), Is.EqualTo(expected));
}

public class EngineLogUnifyTests
{
    private static readonly IReadOnlyList<LuaEvent> NoJobs = Array.Empty<LuaEvent>();

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
    public void Unify_StartsAtNow_ThenEmitsNewLinesInOrder_DropsMcpNoise()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            File.AppendAllText(p, "boot line before anchor\n");
            log.AnchorAtLaunch();
            Assert.That(log.Unify(NoJobs), Is.Empty, "start-at-now: boot is not replayed");

            File.AppendAllText(p, "engine one\n[MCP] bridge noise\nengine two\n");
            var u = log.Unify(NoJobs);

            Assert.That(u.Select(e => e.Text), Is.EqualTo(new[] { "engine one", "engine two" }));
            Assert.That(u.All(e => e.Kind == "engine"), Is.True);
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void Unify_TypesRealErrorLines_AsError_GroupingTheStack()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            log.Unify(NoJobs); // settle start-at-now
            File.AppendAllText(p, "[ERROR] addon/foo.lua:3: boom\n  1. stack frame\nnormal line\n");

            var u = log.Unify(NoJobs);

            Assert.That(u, Has.Count.EqualTo(2));
            Assert.That(u[0].Kind, Is.EqualTo("error"));
            Assert.That(u[0].Text, Does.Contain("boom").And.Contain("1. stack frame"));
            Assert.That(u[1].Kind, Is.EqualTo("engine"));
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
            log.Unify(NoJobs);
            for (var i = 0; i < 4; i++) File.AppendAllText(p, "Bad SetLocalOrigin(nan) on prop\n");

            var u = log.Unify(NoJobs);

            Assert.That(u, Has.Count.EqualTo(1));
            Assert.That(u[0].Count, Is.EqualTo(4));
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void Unify_AppendsJobCompletions()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            log.Unify(NoJobs);
            File.AppendAllText(p, "engine line\n");

            var u = log.Unify(new[] { new LuaEvent("job", "job mcp_job_2 finished ok") });

            Assert.That(u.Select(e => e.Kind), Is.EqualTo(new[] { "engine", "job" }));
            Assert.That(u[1].Text, Does.Contain("mcp_job_2"));
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void Unify_MapChange_DropsPreviousMapOutput()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch();
            log.Unify(NoJobs); // settle start-at-now
            File.AppendAllText(p,
                "old map line\n" +
                "---- Host_Changelevel ----\n" +
                "new map line one\nnew map line two\n");

            var u = log.Unify(NoJobs);

            Assert.That(u.Select(e => e.Text), Is.EqualTo(new[] { "new map line one", "new map line two" }),
                "the pre-change output is dropped, not stacked under the new map");
        }
        finally { Directory.Delete(tmp, true); }
    }

    [Test]
    public void ScanBoot_ScopesToFinalMap_AndDedupsErrors()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            log.AnchorAtLaunch(); // launch offset = 0 (empty file)
            File.AppendAllText(p,
                "[ERROR] bootstrap/gm.lua:1: gm_construct-stage error\n  1. stack\n" +  // dropped at the map change
                "Dropped Someone from server (Server shutting down)\n" +                 // map change -> reset
                "[aaa] final.lua:4: final map error\n   2. unknown - final.lua:4\n" +     // final map, load error (stack)
                "[aaa] final.lua:4: final map error\n   2. unknown - final.lua:4\n" +     // per-realm dup -> collapsed
                "some clean line\n");

            var boot = log.ScanBoot();

            Assert.That(boot.LuaErrors, Has.Count.EqualTo(1),
                "gm_construct dropped at the map change; the final-map error is detected by stack and deduped");
            Assert.That(boot.LuaErrors[0], Does.Contain("final map error"));
            Assert.That(boot.TotalLines, Is.GreaterThan(0));
        }
        finally { Directory.Delete(tmp, true); }
    }
}

public class EmitUnifiedEventsTests
{
    [Test]
    public void EmitUnifiedEvents_WritesJsonBlock_WithCount_PreservingPrimary()
    {
        var result = new CallToolResult
        {
            Content = new List<ContentBlock> { new TextContentBlock { Text = "primary" } },
        };
        var events = new[]
        {
            new UnifiedEvent("engine", "Bad SetLocalOrigin", 3),
            new UnifiedEvent("error", "foo:3: boom", 1),
        };

        Program.EmitUnifiedEvents(result, events);

        var texts = result.Content!.OfType<TextContentBlock>().Select(t => t.Text).ToList();
        Assert.That(texts, Has.Some.EqualTo("primary"));
        var ev = texts.First(t => t.StartsWith("events:"));
        Assert.That(ev, Does.Contain("\"count\":3"));
        Assert.That(ev, Does.Contain("\"kind\":\"error\""));
        Assert.That(ev, Does.Contain("Bad SetLocalOrigin").And.Contain("foo:3: boom"));
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

public class EngineLogReadTests
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
    public void Read_FilterAppliesBeforeLimit_FindsMatchesBeyondTheLastNLines()
    {
        var (log, p, tmp) = NewLog();
        try
        {
            File.AppendAllText(p, "[ERROR] one\n");
            for (var i = 0; i < 50; i++) File.AppendAllText(p, $"noise {i}\n");
            File.AppendAllText(p, "[ERROR] two\n");
            for (var i = 0; i < 50; i++) File.AppendAllText(p, $"trailing noise {i}\n");

            // limit 2 bounds MATCHES, not raw lines — even though no [ERROR] is in the last 2 lines.
            var res = log.Read(0, 2, "[ERROR]");

            Assert.That(res.Lines, Is.EqualTo(new[] { "[ERROR] one", "[ERROR] two" }));
        }
        finally { Directory.Delete(tmp, true); }
    }
}
