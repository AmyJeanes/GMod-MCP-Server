namespace GModMcpServer.Host;

/// <summary>
/// Host-side access to GMod's engine console log (<c>garrysmod/console.log</c>) and the
/// producer of the unified <c>events</c> stream. Singleton.
///
/// <c>console.log</c> is the single source: it already contains engine output and both
/// realms' Lua output interleaved in true order, so ordering and game-vs-engine dedup come
/// for free (each line emitted once, in file order). No importance classification and no
/// per-line source enrichment — every non-<c>[MCP]</c> message is surfaced equally as
/// <c>engine</c> (or <c>error</c> for a real <c>[ERROR]</c> line). The one thing that isn't
/// in console.log — background-job completions — is passed through from the Lua ring.
///
/// (Correlating Lua-rail events onto console.log lines to add realm/kind was tried and
/// dropped: the console.log drain runs at response-processing time and almost always leads
/// the Lua event's delivery, so enrichment fired inconsistently — worse than not at all.
/// See docs/engine-log.md.)
/// </summary>
public sealed class EngineLog
{
    private const string LogFileName = "console.log";

    private readonly EngineLogReader _reader;
    private readonly string _path;
    private readonly object _gate = new();
    private long _passiveCursor = -1; // -1 = start-at-now on the next drain
    private long _anchorOffset = -1;  // where the current map's boot begins (set by Anchor), for ScanBoot

    public EngineLog(BridgePaths paths)
    {
        _path = ResolvePath(paths.DataPath);
        _reader = new EngineLogReader(_path);
    }

    public string Path => _path;

    public bool Present => File.Exists(_path);

    public DateTime? LastWriteUtc => File.Exists(_path) ? File.GetLastWriteTimeUtc(_path) : null;

    /// <summary>
    /// Mark a new-map boundary (a game launch or an in-game level change): reset the unified
    /// stream to start-at-now on the next drain, and remember the current console.log length as
    /// the boot offset for <see cref="ScanBoot"/>. The new map's boot (two-stage on launch,
    /// hundreds of lines) is thus skipped from the passive stream — it stays available raw via
    /// <c>engine_log</c> — so responses only carry what's new. Call it just before the launch or
    /// changelevel command so the offset lands before any new-map output.
    /// </summary>
    public void Anchor()
    {
        lock (_gate)
        {
            _passiveCursor = -1;            // passive stream starts at now (skips boot)
            _anchorOffset = _reader.Length; // ...but remember where boot begins, for ScanBoot
        }
    }

    /// <summary>
    /// Scan the current map's startup console (from the anchor to now) for Lua errors and
    /// return them deduped, plus the boot line count. We live in the Lua realm, so startup
    /// errors matter — and the passive stream skips boot, so host_launch / host_changelevel
    /// surface these deliberately. Scoped to the FINAL map: a map change resets, so the
    /// two-stage bootstrap's gm_construct stage falls away; the full startup console stays
    /// available raw via engine_log.
    /// </summary>
    public BootScan ScanBoot()
    {
        lock (_gate)
        {
            if (_anchorOffset < 0) return BootScan.Empty;

            var cursor = _anchorOffset;
            var messages = EngineLogGrouping.Group(_reader.ReadFrom(ref cursor));

            // Scope to the FINAL map: a map change (the two-stage bootstrap's `map` transition,
            // then any later one) resets, so gm_construct's errors fall away. Then dedup — the
            // final map still loads each addon per realm, so identical errors repeat.
            var errors = new List<string>();
            var seen = new HashSet<string>();
            var lines = 0;
            foreach (var m in messages)
            {
                if (EngineLogFilter.IsMapChange(m.Header)) { errors.Clear(); seen.Clear(); lines = 0; continue; }
                lines++;
                if (EngineLogFilter.IsLuaError(m.Header, m.Text) && seen.Add(m.Text)) errors.Add(m.Text);
            }
            return new BootScan(lines, errors);
        }
    }

    /// <summary>
    /// Produce the unified events for this response: new console.log lines since the last
    /// drain, in file order — each <c>engine</c> (or <c>error</c> for a real <c>[ERROR]</c>),
    /// <c>[MCP]</c> dropped, consecutive identical collapsed with a count — then the passed-in
    /// job-completion events appended (those are synthetic and not in console.log).
    /// </summary>
    public IReadOnlyList<UnifiedEvent> Unify(IReadOnlyList<LuaEvent> jobEvents)
    {
        lock (_gate)
        {
            List<UnifiedEvent> outEvents;
            if (_passiveCursor < 0)
            {
                _passiveCursor = _reader.Length; // start-at-now: skip history
                outEvents = new List<UnifiedEvent>();
            }
            else
            {
                var raw = new List<UnifiedEvent>();
                foreach (var m in EngineLogGrouping.Group(_reader.ReadFrom(ref _passiveCursor)))
                {
                    // A map change resets "current map": drop the old map's output drained in
                    // this batch so a map switch doesn't dump the whole new boot atop the old.
                    if (EngineLogFilter.IsMapChange(m.Header)) { raw.Clear(); continue; }
                    if (EngineLogFilter.IsMcpNoise(m.Header)) continue;
                    var kind = EngineLogFilter.IsLuaError(m.Header, m.Text) ? "error" : "engine";
                    raw.Add(new UnifiedEvent(kind, m.Text, 1));
                }
                outEvents = Collapse(raw);
            }

            foreach (var j in jobEvents) outEvents.Add(new UnifiedEvent("job", j.Text, 1));
            return outEvents;
        }
    }

    /// <summary>
    /// Explicit read for the <c>engine_log</c> tool — the raw console.log tail, no dedup.
    /// <paramref name="since"/> &lt; 0 returns the recent tail; else new lines from that byte
    /// cursor. Optional case-insensitive substring <paramref name="filter"/>.
    /// </summary>
    // When filtering, read a generous window/backlog first so the filter isn't starved by
    // the line limit (the limit applies to matches, not to raw lines scanned).
    private const int FilterScanMaxLines = 20000;

    public EngineLogReadResult Read(long since, int limit, string? filter)
    {
        lock (_gate)
        {
            var hasFilter = !string.IsNullOrEmpty(filter);
            IReadOnlyList<string> lines;
            long cursor;
            var dropped = false;

            if (since < 0)
            {
                (lines, cursor) = _reader.ReadTail(hasFilter ? FilterScanMaxLines : limit);
            }
            else
            {
                var c = since;
                lines = _reader.ReadFrom(ref c);
                if (c < since) dropped = true;
                cursor = c;
            }

            // Filter BEFORE applying the limit, so `limit` bounds matches, not raw lines.
            if (hasFilter)
            {
                lines = lines.Where(l => l.Contains(filter!, StringComparison.OrdinalIgnoreCase)).ToList();
            }
            if (lines.Count > limit)
            {
                lines = lines.Skip(lines.Count - limit).ToList();
                dropped = true;
            }

            return new EngineLogReadResult(lines, cursor, dropped, File.Exists(_path), _path);
        }
    }

    // Collapse consecutive identical messages into one with a count (the console's own
    // (xN); -condebug writes them out raw).
    private static List<UnifiedEvent> Collapse(List<UnifiedEvent> items)
    {
        var outl = new List<UnifiedEvent>();
        foreach (var it in items)
        {
            if (outl.Count > 0 && outl[^1].Kind == it.Kind && outl[^1].Text == it.Text)
            {
                outl[^1] = outl[^1] with { Count = outl[^1].Count + 1 };
            }
            else
            {
                outl.Add(it);
            }
        }
        return outl;
    }

    // dataPath = ...\garrysmod\data ; console.log lives in the mod dir one level up.
    private static string ResolvePath(string dataPath)
    {
        var modDir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(dataPath));
        return modDir is null ? LogFileName : System.IO.Path.Combine(modDir, LogFileName);
    }
}

/// <summary>A passive Lua-ring event passed through for the unified stream — used for
/// job completions (kind "job"), which aren't in console.log.</summary>
public sealed record LuaEvent(string Kind, string Text);

/// <summary>One entry in the unified stream: kind (engine/error/job), text, repeat count.</summary>
public sealed record UnifiedEvent(string Kind, string Text, int Count);

/// <summary>Startup scan of the final map's load: its console line count and the distinct
/// (deduped) Lua errors.</summary>
public sealed record BootScan(int TotalLines, IReadOnlyList<string> LuaErrors)
{
    public static readonly BootScan Empty = new(0, Array.Empty<string>());

    public bool HasErrors => LuaErrors.Count > 0;
}

public sealed record EngineLogReadResult(
    IReadOnlyList<string> Lines, long Cursor, bool Dropped, bool Present, string Path);
