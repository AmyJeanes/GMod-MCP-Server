namespace GModMcpServer.Host;

/// <summary>
/// The only line-level judgments the unified stream makes — no importance
/// classification (every message is surfaced equally, in console.log order). We only
/// distinguish the two things that are about correctness, not priority: our own
/// <c>[MCP]</c> bridge noise (dropped), and Lua error lines (so an uncorrelated one —
/// e.g. a startup error from before capture was live — is typed as an error rather
/// than plain engine output).
/// </summary>
public static class EngineLogFilter
{
    /// <summary>Our own bridge logs — dropped from the unified stream as internal noise.</summary>
    public static bool IsMcpNoise(string header) =>
        header.StartsWith("[MCP]", StringComparison.Ordinal);

    /// <summary>A Lua error line, by the engine's <c>[ERROR]</c> tag. Engine C++ errors
    /// don't use this tag, so it identifies Lua errors specifically.</summary>
    public static bool IsLuaErrorLine(string header) =>
        header.StartsWith("[ERROR]", StringComparison.Ordinal);
}
