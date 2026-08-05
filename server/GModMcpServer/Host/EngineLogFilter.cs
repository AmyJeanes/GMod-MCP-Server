using System.Text.RegularExpressions;

namespace GModMcpServer.Host;

/// <summary>
/// The only line-level judgments the unified stream makes — no importance classification
/// (every message is surfaced equally, in console.log order). We only distinguish the two
/// things that are about correctness, not priority: our own <c>[MCP]</c> bridge noise
/// (dropped), and Lua errors (so they're typed as <c>error</c>).
/// </summary>
public static partial class EngineLogFilter
{
    /// <summary>Our own bridge logs — dropped from the unified stream as internal noise.</summary>
    public static bool IsMcpNoise(string header) =>
        header.StartsWith("[MCP]", StringComparison.Ordinal);

    /// <summary>
    /// A map change is starting — the reset boundary for "current map". Matched with an anchored
    /// regex (a whole-line match, not a loose substring) so a player name or a chat line that
    /// merely contains a marker phrase can't trigger a false reset. The signals fire at load
    /// START, each on its own console line:
    ///   * <c>---- Host_Changelevel ----</c> — a soft <c>changelevel</c>.
    ///   * <c>Dropped &lt;who&gt; from server (Server shutting down)</c> — a <c>map</c> / hard
    ///     reset / host leave. It's server-wide; an individual player or bot leaving carries its
    ///     OWN reason (<c>(Disconnect by user.)</c>, <c>(Kicked …)</c>, a bot-remove reason), which
    ///     is deliberately NOT matched — anchoring on the full drop line is what excludes those.
    ///   * <c>[MCP] map transition</c> — the sentinel <c>sv_launch_intent.lua</c> emits for the
    ///     two-stage bootstrap, whose <c>map</c> fires so early the engine drops the player as
    ///     <c>(Disconnect by user.)</c> rather than <c>(Server shutting down)</c>.
    /// Together these cover manual changes, host_changelevel, and the bootstrap.
    /// </summary>
    public static bool IsMapChange(string line) => MapChangeLine().IsMatch(line);

    // Whole-line, so a marker phrase inside a player name / chat / other text can't false-match.
    // The shutting-down arm requires the engine's full "Dropped … from server (Server shutting
    // down)" drop line, so a per-player leave (a different reason) and stray occurrences don't hit.
    [GeneratedRegex(@"^(?:---- Host_Changelevel ----|Dropped .+ from server \(Server shutting down\)|\[MCP\] map transition)\s*$")]
    private static partial Regex MapChangeLine();

    /// <summary>
    /// Whether a (grouped) console message is a Lua error. Runtime errors are prefixed
    /// <c>[ERROR]</c>, but load-time / ErrorNoHaltWithStack errors are prefixed with the
    /// addon name instead (<c>[TARDIS] path.lua:12: ...</c>) — so the reliable signal is a
    /// numbered Lua stack trace in the continuation (<c>  1. fn - path:line</c>), which both
    /// carry but a benign bracketed print or the indented <c>Crazy origin</c> block do not.
    /// </summary>
    public static bool IsLuaError(string header, string text) =>
        header.StartsWith("[ERROR]", StringComparison.Ordinal) || StackFrame().IsMatch(text);

    // A continuation line that is a numbered stack frame: newline, indent, digits, ". ".
    [GeneratedRegex(@"\n[ \t]*\d+\.[ \t]")]
    private static partial Regex StackFrame();
}
