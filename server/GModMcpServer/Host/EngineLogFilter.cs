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
    /// A map change is starting — the reset boundary for "current map". The signals fire at
    /// load START (before the new map's addons load), so the new map's load errors fall after
    /// them: <c>changelevel</c> prints <c>---- Host_Changelevel ----</c>; a <c>map</c> / hard
    /// reset drops the host player with <c>(Server shutting down)</c>. The two-stage bootstrap
    /// transition is the exception — its <c>map</c> fires so early the engine drops the player
    /// as <c>(Disconnect by user.)</c>, not <c>(Server shutting down)</c>, so it has no engine
    /// marker; <c>sv_launch_intent.lua</c> emits an explicit <c>[MCP] map transition</c> sentinel
    /// we key on instead. Together these cover manual changes, host_changelevel, and the bootstrap.
    /// </summary>
    public static bool IsMapChange(string line) =>
        line.Contains("---- Host_Changelevel ----", StringComparison.Ordinal)
        || line.Contains("(Server shutting down)", StringComparison.Ordinal)
        || line.Contains("[MCP] map transition", StringComparison.Ordinal);

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
