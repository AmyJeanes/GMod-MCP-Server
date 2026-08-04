namespace GModMcpServer.Host;

/// <summary>How a console.log message is treated by the passive engine rail.</summary>
public enum EngineLineClass
{
    Marker,     // MCP's "lua-error capture active" seam (see CaptureMarker)
    McpNoise,   // our own [MCP] bridge logs
    LuaError,   // "[ERROR] ..." — Lua rail owns these once capture is active
    Warning,    // high-confidence engine-native warning — inlined
    Notable,    // broad "might matter" — counted for the breadcrumb, not inlined
    Benign,     // ignored
}

/// <summary>
/// Classifies console.log message headers for the passive rail. Console.log has no
/// severity or realm markers and interleaves engine output with addon Lua prints, so
/// this can't be exhaustive — it's a <em>highlighter</em>, not a gate. The high-
/// confidence <see cref="Signatures"/> are inlined; a broader "notable" heuristic is
/// only counted (the breadcrumb); everything a caller might still want is in the raw
/// <c>engine_log</c>. All three lists are tuned live against real spew.
/// </summary>
public static class EngineLogFilter
{
    /// <summary>
    /// Emitted by the Lua side (sh_capture.lua) when OnLuaError capture goes active.
    /// Before this line in the stream, console.log is the ONLY source of Lua errors
    /// (the rail didn't exist yet — startup errors); after it, the Lua rail owns them.
    /// </summary>
    public const string CaptureMarker = "lua-error capture active";

    // High-confidence serious engine-native signatures -> inlined. Case-sensitive:
    // engine casing is stable, and it avoids "NaN" matching "nan" inside a word.
    private static readonly string[] Signatures =
    {
        "Bad SetLocalOrigin", "Bad SetLocalAngles", "Crazy origin",
        "unreasonable position", "NaN", "Host_Error", "Engine Error",
        "SetupBones", "Bad bone", "overflow",
    };

    // Broad "might matter" hints for the breadcrumb count (case-insensitive; a fuzzy
    // "go look" signal, so over-counting is acceptable).
    private static readonly string[] NotableHints =
    {
        "Warning", "Error", "Bad ", "Invalid", "Failed", "Cannot", "NaN", "overflow", "Assert",
    };

    // Specific high-volume benign lines kept OUT of the notable count (observed spam).
    private static readonly string[] BenignHints =
    {
        "Requesting texture value", "KeyValues Error", "custom font file",
        "Extended Spawnmenu", "Adding Filesystem Addon", "Mounted ", "ErrorAPI",
    };

    public static EngineLineClass Classify(string header)
    {
        if (string.IsNullOrEmpty(header)) return EngineLineClass.Benign;
        // Marker before McpNoise: the marker line is itself an [MCP] line.
        if (header.Contains(CaptureMarker, StringComparison.Ordinal)) return EngineLineClass.Marker;
        if (header.StartsWith("[ERROR]", StringComparison.Ordinal)) return EngineLineClass.LuaError;
        if (header.StartsWith("[MCP]", StringComparison.Ordinal)) return EngineLineClass.McpNoise;
        foreach (var s in Signatures)
        {
            if (header.Contains(s, StringComparison.Ordinal)) return EngineLineClass.Warning;
        }
        return IsNotable(header) ? EngineLineClass.Notable : EngineLineClass.Benign;
    }

    private static bool IsNotable(string header)
    {
        foreach (var b in BenignHints)
        {
            if (header.Contains(b, StringComparison.OrdinalIgnoreCase)) return false;
        }
        foreach (var h in NotableHints)
        {
            if (header.Contains(h, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }
}
