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

public class EngineLogFilterTests
{
    // Real engine-native lines (from the live console.log) surface; benign spam,
    // Lua errors ([ERROR], owned by the cleaner Lua rail) and our own [MCP] logs don't.
    [TestCase("prop_physics[230]:SetPos( 1000000000 ): Ignoring unreasonable position.", true)]
    [TestCase("Bad SetLocalOrigin(-14275.8,18038.9,-12359.9) on gmod_tardis_part_door", true)]
    [TestCase("Crazy origin on entity [511][gmod_tardis_part_door]", true)]
    [TestCase("Requesting texture value from var \"$basetexture\" which is not a texture value", false)]
    [TestCase("[ERROR] mcp_lua_run:9: something about unreasonable position", false)]
    [TestCase("[MCP] Bridge polling started (client).", false)]
    [TestCase("Zippy's library loaded!", false)]
    [TestCase("", false)]
    public void IsInteresting(string line, bool expected) =>
        Assert.That(EngineLogFilter.IsInteresting(line), Is.EqualTo(expected));
}

public class EngineLogServiceTests
{
    [Test]
    public void DrainPassive_AfterAnchor_ReturnsOnlyCuratedLinesFromThisSession()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "mcp_el_" + Guid.NewGuid().ToString("N"));
        var dataDir = Path.Combine(tmp, "data");
        Directory.CreateDirectory(dataDir);
        var logPath = Path.Combine(tmp, "console.log");
        try
        {
            // Prior session's accumulated output (-condebug appends across launches).
            File.WriteAllText(logPath, "old session: Crazy origin on entity [99]\n");

            var log = new EngineLog(new BridgePaths("", "", dataDir));
            Assert.That(log.Path, Does.EndWith("console.log"));
            Assert.That(log.Present, Is.True);

            log.AnchorAtLaunch(); // scope past the old line

            File.AppendAllText(logPath, "Zippy loaded\nCrazy origin on entity [1]\ntexture noise\n");

            Assert.That(log.DrainPassive(), Is.EqualTo(new[] { "Crazy origin on entity [1]" }),
                "only this session's curated engine warnings, not the old history or benign noise");
            Assert.That(log.DrainPassive(), Is.Empty, "nothing new on a second drain");
        }
        finally
        {
            if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        }
    }

    [Test]
    public void DrainPassive_WithoutAnchor_StartsAtNow_NoBacklog()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "mcp_el_" + Guid.NewGuid().ToString("N"));
        var dataDir = Path.Combine(tmp, "data");
        Directory.CreateDirectory(dataDir);
        var logPath = Path.Combine(tmp, "console.log");
        try
        {
            File.WriteAllText(logPath, "Crazy origin on entity [7]\n"); // pre-existing
            var log = new EngineLog(new BridgePaths("", "", dataDir));

            // No AnchorAtLaunch (game started externally / host restarted): first drain
            // starts at now, so the backlog isn't replayed.
            Assert.That(log.DrainPassive(), Is.Empty);

            File.AppendAllText(logPath, "Bad SetLocalOrigin(1,2,3) on foo\n");
            Assert.That(log.DrainPassive(), Is.EqualTo(new[] { "Bad SetLocalOrigin(1,2,3) on foo" }));
        }
        finally
        {
            if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        }
    }
}

public class AppendEngineEventsTests
{
    [Test]
    public void AppendEngineEvents_AddsTrailingBlock_PreservingPrimaryContent()
    {
        var result = new CallToolResult
        {
            Content = new List<ContentBlock> { new TextContentBlock { Text = "primary" } },
        };

        Program.AppendEngineEvents(result, new[] { "Bad SetLocalOrigin(...) on door" });

        var texts = result.Content!.OfType<TextContentBlock>().Select(t => t.Text).ToList();
        Assert.That(texts, Has.Some.EqualTo("primary"), "the primary result block survives");
        Assert.That(texts, Has.Some.Contains("engine_events"));
        Assert.That(texts, Has.Some.Contains("Bad SetLocalOrigin"));
    }

    [Test]
    public void AppendEngineEvents_NoOp_WhenNoLines()
    {
        var result = new CallToolResult
        {
            Content = new List<ContentBlock> { new TextContentBlock { Text = "primary" } },
        };

        Program.AppendEngineEvents(result, Array.Empty<string>());

        Assert.That(result.Content!, Has.Count.EqualTo(1));
    }
}
