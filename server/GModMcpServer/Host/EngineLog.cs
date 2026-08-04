namespace GModMcpServer.Host;

/// <summary>
/// Host-side access to GMod's engine console log (<c>garrysmod/console.log</c>).
/// Singleton: owns the passive read cursor and the per-launch anchor. Two consumers
/// — the passive <c>engine_events</c> injector (Program.CallToolAsync) and the
/// explicit <c>engine_log</c> tool — read through it. Every read is on-demand at
/// tool-call time; there's no background thread.
///
/// See <c>docs/engine-log.md</c> for the empirical basis (path, append-not-truncate,
/// shared-read, no realm attribution).
/// </summary>
public sealed class EngineLog
{
    private const string LogFileName = "console.log";

    private readonly EngineLogReader _reader;
    private readonly string _path;
    private readonly object _gate = new();
    private long _passiveCursor = -1; // -1 = not yet anchored (start-at-now on first drain)
    private bool _luaCaptureActive;   // flipped true by the capture marker in the stream

    public EngineLog(BridgePaths paths)
    {
        _path = ResolvePath(paths.DataPath);
        _reader = new EngineLogReader(_path);
    }

    public string Path => _path;

    public bool Present => File.Exists(_path);

    public DateTime? LastWriteUtc => File.Exists(_path) ? File.GetLastWriteTimeUtc(_path) : null;

    /// <summary>
    /// Anchor passive surfacing to the current end of file. Called at launch: the
    /// file, if present, holds prior sessions' output (-condebug appends), and this
    /// session appends after it — so anchoring here scopes passive events to this
    /// session (boot spew included) without dumping old history.
    /// </summary>
    public void AnchorAtLaunch()
    {
        lock (_gate)
        {
            _passiveCursor = _reader.Length;
            _luaCaptureActive = false; // a fresh session's Lua capture isn't active until its marker
        }
    }

    /// <summary>
    /// Curated engine-native warnings since the last passive read, for
    /// <c>engine_events</c>. If never anchored (e.g. the game was launched from Steam,
    /// or the host restarted mid-game), the first call starts at now so it doesn't
    /// replay accumulated history.
    /// </summary>
    public PassiveEngineResult DrainPassive()
    {
        lock (_gate)
        {
            if (_passiveCursor < 0)
            {
                _passiveCursor = _reader.Length; // start-at-now (no launch anchor): don't replay history
                return PassiveEngineResult.Empty;
            }
            var lines = _reader.ReadFrom(ref _passiveCursor);
            if (lines.Count == 0) return PassiveEngineResult.Empty;

            var messages = EngineLogGrouping.Group(lines);
            var surfaced = new List<(string Text, bool Startup)>();
            var notable = 0;

            foreach (var m in messages)
            {
                switch (EngineLogFilter.Classify(m.Header))
                {
                    case EngineLineClass.Marker:
                        _luaCaptureActive = true;
                        break;
                    case EngineLineClass.LuaError:
                        // Before capture is active these are startup errors only
                        // console.log has; after, the Lua rail owns them (cleaner), so
                        // don't double-report.
                        if (!_luaCaptureActive) surfaced.Add((m.Text, true));
                        break;
                    case EngineLineClass.Warning:
                        surfaced.Add((m.Text, false));
                        break;
                    case EngineLineClass.Notable:
                        notable++;
                        break;
                    // McpNoise / Benign: ignored.
                }
            }

            return new PassiveEngineResult(Collapse(surfaced), notable);
        }
    }

    // Collapse consecutive identical surfaced messages into one with a count — the
    // console's (xN) behaviour, which -condebug writes out raw (see docs/engine-log.md).
    private static List<EngineHighlight> Collapse(List<(string Text, bool Startup)> items)
    {
        var outl = new List<EngineHighlight>();
        foreach (var it in items)
        {
            if (outl.Count > 0 && outl[^1].Text == it.Text && outl[^1].StartupError == it.Startup)
            {
                outl[^1] = outl[^1] with { Count = outl[^1].Count + 1 };
            }
            else
            {
                outl.Add(new EngineHighlight(it.Text, 1, it.Startup));
            }
        }
        return outl;
    }

    /// <summary>
    /// Explicit read for the <c>engine_log</c> tool. <paramref name="since"/> &lt; 0
    /// returns the recent tail (last <paramref name="limit"/> lines); otherwise
    /// returns new lines from that byte cursor. Optional case-insensitive substring
    /// <paramref name="filter"/>. Returns the raw tail — no allowlist.
    /// </summary>
    public EngineLogReadResult Read(long since, int limit, string? filter)
    {
        lock (_gate)
        {
            IReadOnlyList<string> lines;
            long cursor;
            var dropped = false;

            if (since < 0)
            {
                (lines, cursor) = _reader.ReadTail(limit);
            }
            else
            {
                var c = since;
                var read = _reader.ReadFrom(ref c);
                if (c < since) dropped = true; // cursor was reset — the file shrank/rotated
                if (read.Count > limit)
                {
                    read = read.Skip(read.Count - limit).ToList();
                    dropped = true;
                }
                lines = read;
                cursor = c;
            }

            if (!string.IsNullOrEmpty(filter))
            {
                lines = lines.Where(l => l.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();
            }

            return new EngineLogReadResult(lines, cursor, dropped, File.Exists(_path), _path);
        }
    }

    // dataPath = ...\garrysmod\data ; console.log lives in the mod dir one level up.
    private static string ResolvePath(string dataPath)
    {
        var modDir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(dataPath));
        return modDir is null ? LogFileName : System.IO.Path.Combine(modDir, LogFileName);
    }
}

public sealed record EngineLogReadResult(
    IReadOnlyList<string> Lines, long Cursor, bool Dropped, bool Present, string Path);

/// <summary>One inlined passive message: text (grouped), its repeat count, and whether
/// it's a pre-capture startup Lua error (which only console.log has).</summary>
public sealed record EngineHighlight(string Text, int Count, bool StartupError);

/// <summary>The passive engine rail's output for one drain: inlined highlights plus a
/// count of other "notable" lines not inlined (the breadcrumb).</summary>
public sealed record PassiveEngineResult(IReadOnlyList<EngineHighlight> Highlights, int OtherNotableCount)
{
    public static readonly PassiveEngineResult Empty = new(Array.Empty<EngineHighlight>(), 0);

    public bool IsEmpty => Highlights.Count == 0 && OtherNotableCount == 0;
}
