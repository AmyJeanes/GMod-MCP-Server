namespace GModMcpServer.Host;

/// <summary>
/// Decides which console.log lines are surfaced <em>passively</em> (on tool
/// results' <c>engine_events</c>). Deliberately a conservative allowlist of serious
/// engine-native signatures: console.log is dominated by benign texture / material
/// / spawnmenu spam, so surfacing everything would flood the rail. The
/// <c>engine_log</c> tool returns the raw, unfiltered tail for the full picture.
///
/// Lua errors are excluded on purpose — they appear in console.log as
/// <c>[ERROR] ...</c> plus an indented stack, but the Lua rail
/// (<c>console_read</c> / passive <c>events</c>) already carries them cleaner
/// (structured, per-realm, no stack noise). Engine C++ errors don't use the
/// <c>[ERROR]</c> tag, so dropping it removes only the Lua duplicates.
/// </summary>
public static class EngineLogFilter
{
    // Case-sensitive: engine warning strings have stable casing, and matching
    // exact case avoids false positives (e.g. "NaN" not matching "nan" inside a
    // word). Extend as new serious signatures surface in live use.
    private static readonly string[] Signatures =
    {
        "Bad SetLocalOrigin",
        "Bad SetLocalAngles",
        "Crazy origin",
        "unreasonable position",
        "NaN",
        "Host_Error",
        "Engine Error",
        "SetupBones",
        "Bad bone",
        "Overflow",
    };

    public static bool IsInteresting(string line)
    {
        if (string.IsNullOrEmpty(line)) return false;
        if (line.StartsWith("[ERROR]", StringComparison.Ordinal)) return false; // Lua rail owns these
        if (line.StartsWith("[MCP]", StringComparison.Ordinal)) return false;   // our own bridge logs
        foreach (var s in Signatures)
        {
            if (line.Contains(s, StringComparison.Ordinal)) return true;
        }
        return false;
    }
}
