using System.Text;

namespace GModMcpServer.Host;

/// <summary>
/// Tails GMod's engine console log (<c>garrysmod/console.log</c>, produced by
/// <c>-condebug</c>). Pure file I/O with no persistent state — the caller owns the
/// byte cursor — so it's unit-testable against a temp file.
///
/// Reads use <see cref="FileShare.ReadWrite"/> because the engine holds the file
/// open for writing the whole time (verified: shared reads succeed live). Decoding
/// is Latin1 so every byte maps to exactly one char — byte offsets equal char
/// indices, which keeps the cursor math exact — and no byte sequence can throw.
///
/// <c>-condebug</c> APPENDS across launches (never truncates), so the file
/// accumulates every session; callers anchor their cursor per-launch rather than
/// reading from 0. A cursor past end-of-file (the file was deleted/rotated) resets
/// to 0. A trailing partial line (caught mid-write) is held back until its newline
/// arrives.
/// </summary>
public sealed class EngineLogReader
{
    // Cap a single incremental read so a first read against a multi-MB backlog is
    // bounded; the next call continues from the advanced cursor.
    private const int MaxChunkBytes = 1 << 20; // 1 MiB
    // How far back a no-cursor "tail" read looks.
    private const int TailWindowBytes = 256 * 1024;

    private readonly string _path;

    public EngineLogReader(string path) => _path = path;

    public bool Exists => File.Exists(_path);

    public long Length => File.Exists(_path) ? new FileInfo(_path).Length : 0;

    /// <summary>
    /// Return complete lines from <paramref name="cursor"/> up to the last newline,
    /// advancing the cursor past them. Empty when there's nothing new or only a
    /// partial line. Resets the cursor to 0 if it points past end-of-file.
    /// </summary>
    public IReadOnlyList<string> ReadFrom(ref long cursor)
    {
        if (!File.Exists(_path)) { cursor = 0; return Array.Empty<string>(); }

        using var fs = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var len = fs.Length;
        if (cursor > len) cursor = 0;          // truncated / rotated -> restart
        if (cursor >= len) return Array.Empty<string>();

        var toRead = (int)Math.Min(len - cursor, MaxChunkBytes);
        fs.Seek(cursor, SeekOrigin.Begin);
        var buf = new byte[toRead];
        var n = ReadFull(fs, buf, toRead);
        var text = Encoding.Latin1.GetString(buf, 0, n);

        var lastNl = text.LastIndexOf('\n');
        if (lastNl < 0)
        {
            // No complete line. Advance past a capped chunk (a pathological unbroken
            // run) so we don't stall; otherwise hold and wait for the newline.
            if (n >= MaxChunkBytes) cursor += n;
            return Array.Empty<string>();
        }

        var complete = text.Substring(0, lastNl); // excludes the final '\n'
        cursor += lastNl + 1;                      // Latin1: char count == byte count
        return SplitLines(complete);
    }

    /// <summary>
    /// Return the last <paramref name="maxLines"/> complete lines and the
    /// end-of-file cursor (so a follow-up read with that cursor continues from here).
    /// Reads only a bounded window off the end of the file.
    /// </summary>
    public (IReadOnlyList<string> Lines, long Cursor) ReadTail(int maxLines)
    {
        if (!File.Exists(_path)) return (Array.Empty<string>(), 0);

        using var fs = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var len = fs.Length;
        var start = Math.Max(0, len - TailWindowBytes);
        fs.Seek(start, SeekOrigin.Begin);
        var toRead = (int)(len - start);
        var buf = new byte[toRead];
        var n = ReadFull(fs, buf, toRead);
        var text = Encoding.Latin1.GetString(buf, 0, n);

        if (start > 0)
        {
            // Started mid-line; drop the partial first line.
            var firstNl = text.IndexOf('\n');
            text = firstNl >= 0 ? text.Substring(firstNl + 1) : "";
        }

        var lines = SplitLines(text.TrimEnd('\n'));
        if (lines.Count > maxLines)
        {
            lines = lines.Skip(lines.Count - maxLines).ToList();
        }
        return (lines, len);
    }

    private static List<string> SplitLines(string block)
    {
        if (block.Length == 0) return new List<string>();
        var raw = block.Split('\n');
        var lines = new List<string>(raw.Length);
        foreach (var l in raw) lines.Add(l.TrimEnd('\r'));
        return lines;
    }

    private static int ReadFull(Stream s, byte[] buf, int count)
    {
        var off = 0;
        while (off < count)
        {
            var got = s.Read(buf, off, count - off);
            if (got <= 0) break; // EOF (the file may have been appended-to concurrently; snapshot is fine)
            off += got;
        }
        return off;
    }
}
