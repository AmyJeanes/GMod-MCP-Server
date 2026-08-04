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
        lock (_gate) { _passiveCursor = _reader.Length; }
    }

    /// <summary>
    /// Curated engine-native warnings since the last passive read, for
    /// <c>engine_events</c>. If never anchored (e.g. the game was launched from Steam,
    /// or the host restarted mid-game), the first call starts at now so it doesn't
    /// replay accumulated history.
    /// </summary>
    public IReadOnlyList<string> DrainPassive()
    {
        lock (_gate)
        {
            if (_passiveCursor < 0)
            {
                _passiveCursor = _reader.Length;
                return Array.Empty<string>();
            }
            var lines = _reader.ReadFrom(ref _passiveCursor);
            if (lines.Count == 0) return Array.Empty<string>();
            var kept = new List<string>();
            foreach (var l in lines)
            {
                if (EngineLogFilter.IsInteresting(l)) kept.Add(l);
            }
            return kept;
        }
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
