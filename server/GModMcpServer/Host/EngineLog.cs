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
/// the Lua event's delivery, so enrichment fired inconsistently — worse than not at all.)
///
/// </summary>
public sealed class EngineLog
{
    private const string LogFileName = "console.log";

    private const string MapChangeNotice =
        "(map change detected - the new map's startup console is suppressed here; read it with engine_log)";

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
    ///
    /// A console-initiated map change (its marker reached mid-drain) auto-anchors: the old map's
    /// tail is dropped, the incoming boot is skipped by jumping to now (it stays on-demand via
    /// <c>engine_log</c>), and a single <c>map_change</c> notice is emitted in its place — so a
    /// manual <c>map</c>/<c>changelevel</c> doesn't flood the next tool call with the whole new
    /// boot. (Tool-driven changes anchor via <see cref="Anchor"/> and never reach this branch.)
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
                var mapChanged = false;
                foreach (var m in EngineLogGrouping.Group(_reader.ReadFrom(ref _passiveCursor)))
                {
                    // A console-initiated map change: treat it like Anchor — drop the old map's
                    // tail, jump to now so the new map's boot is skipped (on-demand via
                    // engine_log), and emit one notice below instead of the flood.
                    if (EngineLogFilter.IsMapChange(m.Header))
                    {
                        raw.Clear();
                        mapChanged = true;
                        _passiveCursor = _reader.Length;
                        break;
                    }
                    if (EngineLogFilter.IsMcpNoise(m.Header)) continue;
                    var kind = EngineLogFilter.IsLuaError(m.Header, m.Text) ? "error" : "engine";
                    raw.Add(new UnifiedEvent(kind, m.Text, 1));
                }
                outEvents = Collapse(raw);
                if (mapChanged) outEvents.Add(new UnifiedEvent("map_change", MapChangeNotice, 1));
            }

            foreach (var j in jobEvents) outEvents.Add(new UnifiedEvent("job", j.Text, 1));
            return outEvents;
        }
    }

    /// <summary>
    /// Explicit read for the <c>engine_log</c> tool. Unfiltered: the raw console.log tail (no
    /// grouping, no dedup) — the ground-truth "give me everything" read. With a
    /// <paramref name="filter"/> substring and/or a <paramref name="kind"/>
    /// (error/engine/map_change, classified like the passive stream), it switches to
    /// message-aware selection: lines are grouped into whole logical messages (header + indented
    /// continuation) and a match returns the message intact — so a multi-line Lua error is never
    /// shredded into orphaned frames, and a <c>kind</c> read excludes benign lines a bare
    /// substring would catch (e.g. <c>ErrorAPI:</c>). <paramref name="since"/> &lt; 0 returns the
    /// recent tail; else new lines from that byte cursor.
    /// </summary>
    // When selecting by filter/kind, read a generous window first so the match isn't starved by
    // the line limit (the limit bounds whole matched messages, not the raw lines scanned).
    private const int FilterScanMaxLines = 20000;

    public EngineLogReadResult Read(long since, int limit, string? filter, string? kind = null)
    {
        lock (_gate)
        {
            var messageMode = !string.IsNullOrEmpty(filter) || !string.IsNullOrEmpty(kind);
            IReadOnlyList<string> lines;
            long cursor;
            var dropped = false;

            if (since < 0)
            {
                (lines, cursor) = _reader.ReadTail(messageMode ? FilterScanMaxLines : limit);
            }
            else
            {
                var c = since;
                lines = _reader.ReadFrom(ref c);
                if (c < since) dropped = true;
                cursor = c;
            }

            if (!messageMode)
            {
                // Raw tail: keep the most recent `limit` lines verbatim.
                if (lines.Count > limit)
                {
                    lines = lines.Skip(lines.Count - limit).ToList();
                    dropped = true;
                }
                return new EngineLogReadResult(lines, cursor, dropped, File.Exists(_path), _path);
            }

            // Group first so a match pulls its WHOLE message (header + frames), never a fragment;
            // `limit` then bounds whole matched messages (most recent) so output is never split.
            var matched = EngineLogGrouping.Group(lines)
                .Where(m => MatchesKind(m, kind) && MatchesFilter(m, filter))
                .ToList();
            var selected = TakeRecentWithinLineBudget(matched, limit, ref dropped);
            var outLines = selected.SelectMany(m => m.Text.Split('\n')).ToList();
            return new EngineLogReadResult(outLines, cursor, dropped, File.Exists(_path), _path);
        }
    }

    private static bool MatchesFilter(EngineLogMessage m, string? filter) =>
        string.IsNullOrEmpty(filter) || m.Text.Contains(filter, StringComparison.OrdinalIgnoreCase);

    // kind mirrors the passive stream's taxonomy (EngineLogFilter): a real Lua error, a
    // map-change boundary, or "engine" for everything else ([MCP] noise excluded, as passively).
    private static bool MatchesKind(EngineLogMessage m, string? kind) => kind switch
    {
        null or "" => true,
        "error" => EngineLogFilter.IsLuaError(m.Header, m.Text),
        "map_change" => EngineLogFilter.IsMapChange(m.Header),
        "engine" => !EngineLogFilter.IsMcpNoise(m.Header)
                    && !EngineLogFilter.IsLuaError(m.Header, m.Text)
                    && !EngineLogFilter.IsMapChange(m.Header),
        _ => true,
    };

    // Keep the most recent whole messages that fit the line budget; never split one. Always keep
    // at least the most recent match; flag `dropped` when older matches are cut.
    private static List<EngineLogMessage> TakeRecentWithinLineBudget(
        List<EngineLogMessage> messages, int limit, ref bool dropped)
    {
        var picked = new List<EngineLogMessage>();
        var used = 0;
        for (var i = messages.Count - 1; i >= 0; i--)
        {
            var n = messages[i].Text.Count(c => c == '\n') + 1;
            if (picked.Count > 0 && used + n > limit) { dropped = true; break; }
            picked.Add(messages[i]);
            used += n;
        }
        picked.Reverse();
        return picked;
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
