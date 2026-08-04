namespace GModMcpServer.Host;

/// <summary>
/// Host-side access to GMod's engine console log (<c>garrysmod/console.log</c>) and the
/// producer of the unified <c>events</c> stream. Singleton.
///
/// The unified stream uses <c>console.log</c> as the single spine — it already contains
/// engine output and both realms' Lua output interleaved in true order — so ordering and
/// game-vs-engine dedup come for free (each line is emitted once, in file order). The Lua
/// rail is only an <em>enrichment side-input</em>: its events (fed in per response) are
/// buffered and matched against console.log lines by exact text (errors by substring, since
/// the rail carries the clean message and the file has <c>[ERROR] …</c> + stack), so a
/// Lua-originated line is shown once in its clean, realm-tagged form rather than twice. No
/// importance classification — every non-<c>[MCP]</c> message is surfaced equally.
///
/// See <c>docs/engine-log.md</c> for the empirical basis and the timing caveat.
/// </summary>
public sealed class EngineLog
{
    private const string LogFileName = "console.log";
    private const int MaxBufferedLuaEvents = 2000;

    private readonly EngineLogReader _reader;
    private readonly string _path;
    private readonly object _gate = new();
    private readonly List<BufferedLua> _buffer = new();
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
    /// Anchor the unified stream to the current end of file, and clear the correlation
    /// buffer. Called at launch: this session's output starts here (-condebug appends), so
    /// anchoring scopes to it without replaying prior sessions; old buffered Lua events are
    /// stale.
    /// </summary>
    public void AnchorAtLaunch()
    {
        lock (_gate)
        {
            _passiveCursor = _reader.Length;
            _buffer.Clear();
        }
    }

    /// <summary>
    /// Produce the unified events for this response: ingest the response's Lua events into
    /// the correlation buffer, drain new console.log lines, and emit them in file order —
    /// each Lua-originated line enriched from the rail (deduped against its raw copy),
    /// engine-native lines raw, <c>[MCP]</c> dropped, consecutive identical messages collapsed
    /// with a count. <paramref name="realm"/> tags the Lua events (the responding realm).
    /// </summary>
    public IReadOnlyList<UnifiedEvent> Unify(IReadOnlyList<LuaEvent> luaEvents, string? realm)
    {
        lock (_gate)
        {
            foreach (var e in luaEvents) _buffer.Add(new BufferedLua(e.Text, e.Kind, realm));
            TrimBuffer();

            if (_passiveCursor < 0)
            {
                // Start-at-now (attaching mid-session): don't replay history.
                _passiveCursor = _reader.Length;
                return Array.Empty<UnifiedEvent>();
            }

            var lines = _reader.ReadFrom(ref _passiveCursor);
            if (lines.Count == 0) return Array.Empty<UnifiedEvent>();

            var messages = EngineLogGrouping.Group(lines);
            var outEvents = new List<UnifiedEvent>();
            foreach (var m in messages)
            {
                if (EngineLogFilter.IsMcpNoise(m.Header)) continue; // our own bridge noise

                var match = TakeMatch(m.Header);
                if (match is not null)
                {
                    // Lua-originated: the rail's clean, realm-tagged form, once.
                    outEvents.Add(new UnifiedEvent(match.Kind, match.Text, match.Realm, 1));
                }
                else if (EngineLogFilter.IsLuaErrorLine(m.Header))
                {
                    // A Lua error with no correlating rail event (e.g. a startup error from
                    // before capture was live): raw, with its stack, typed as an error.
                    outEvents.Add(new UnifiedEvent("error", m.Text, null, 1));
                }
                else
                {
                    // Engine-native (or an un-correlated Lua line): raw, in place.
                    outEvents.Add(new UnifiedEvent("engine", m.Text, null, 1));
                }
            }
            return Collapse(outEvents);
        }
    }

    /// <summary>
    /// Explicit read for the <c>engine_log</c> tool — the raw console.log tail, no dedup or
    /// enrichment. <paramref name="since"/> &lt; 0 returns the recent tail; else new lines
    /// from that byte cursor. Optional case-insensitive substring <paramref name="filter"/>.
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
                if (c < since) dropped = true;
                if (read.Count > limit) { read = read.Skip(read.Count - limit).ToList(); dropped = true; }
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

    // Find and remove the first buffered Lua event whose text this console.log line
    // corresponds to — exact match for print/msg, substring for errors (the rail has the
    // clean message; the file has "[ERROR] <message>" + stack).
    private BufferedLua? TakeMatch(string header)
    {
        for (var i = 0; i < _buffer.Count; i++)
        {
            var b = _buffer[i];
            var matched = b.Kind == "error"
                ? header.Contains(b.Text, StringComparison.Ordinal)
                : header == b.Text;
            if (matched) { _buffer.RemoveAt(i); return b; }
        }
        return null;
    }

    private void TrimBuffer()
    {
        while (_buffer.Count > MaxBufferedLuaEvents) _buffer.RemoveAt(0);
    }

    // Collapse consecutive identical messages into one with a count (the console's own
    // (xN); -condebug writes them out raw).
    private static List<UnifiedEvent> Collapse(List<UnifiedEvent> items)
    {
        var outl = new List<UnifiedEvent>();
        foreach (var it in items)
        {
            if (outl.Count > 0 && outl[^1].Kind == it.Kind && outl[^1].Text == it.Text
                && outl[^1].Realm == it.Realm)
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

    private sealed record BufferedLua(string Text, string Kind, string? Realm);
}

/// <summary>A Lua-rail event fed in for correlation: its kind (print/msg/error) and text.</summary>
public sealed record LuaEvent(string Kind, string Text);

/// <summary>One entry in the unified stream: kind, text, optional realm (Lua-originated), and
/// a repeat count.</summary>
public sealed record UnifiedEvent(string Kind, string Text, string? Realm, int Count);

public sealed record EngineLogReadResult(
    IReadOnlyList<string> Lines, long Cursor, bool Dropped, bool Present, string Path);
