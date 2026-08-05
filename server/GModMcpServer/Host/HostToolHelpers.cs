using System.Text.Json;
using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host;

internal static class HostToolHelpers
{
    public static JsonElement ParseSchema(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.Clone();
    }

    /// <summary>
    /// Attach a boot-scan summary to a launch/changelevel result: a <c>startup_log</c> note (line
    /// count + a pointer to engine_log for the full console) and, when any, a <c>boot_lua_errors</c>
    /// list of the distinct startup Lua errors. <paramref name="boundaryPhrase"/> names the boundary
    /// in the note ("launch" / "the level change"). Shared so the two tools' prose can't drift.
    /// </summary>
    public static void AttachBootScan(JsonObject result, BootScan boot, string boundaryPhrase)
    {
        result["startup_log"] =
            $"{boot.TotalLines} console lines in the loaded map's startup. The passive `events` stream starts "
            + $"fresh after {boundaryPhrase} (boot is not replayed); read the full startup console with engine_log (since: 0).";
        if (boot.HasErrors)
        {
            result["boot_lua_errors"] = ToJsonArray(boot.LuaErrors);
        }
    }

    private static JsonArray ToJsonArray(IReadOnlyList<string> items)
    {
        var arr = new JsonArray();
        foreach (var s in items) arr.Add(s);
        return arr;
    }

    public static CallToolResult Ok(string text) => new()
    {
        Content = new List<ContentBlock> { new TextContentBlock { Text = text } },
        IsError = false,
    };

    public static CallToolResult Err(string message) => new()
    {
        Content = new List<ContentBlock> { new TextContentBlock { Text = message } },
        IsError = true,
    };

    public static string GetString(IDictionary<string, JsonElement>? args, string key, string fallback)
    {
        if (args is null || !args.TryGetValue(key, out var v) || v.ValueKind != JsonValueKind.String) return fallback;
        return v.GetString() ?? fallback;
    }

    public static bool GetBool(IDictionary<string, JsonElement>? args, string key, bool fallback)
    {
        if (args is null || !args.TryGetValue(key, out var v)) return fallback;
        return v.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => fallback,
        };
    }

    public static int GetInt(IDictionary<string, JsonElement>? args, string key, int fallback)
    {
        if (args is null || !args.TryGetValue(key, out var v) || v.ValueKind != JsonValueKind.Number) return fallback;
        return v.TryGetInt32(out var i) ? i : fallback;
    }

    public static bool? GetBoolOrNull(IDictionary<string, JsonElement>? args, string key)
    {
        if (args is null || !args.TryGetValue(key, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }

    public static int? GetIntOrNull(IDictionary<string, JsonElement>? args, string key)
    {
        if (args is null || !args.TryGetValue(key, out var v) || v.ValueKind != JsonValueKind.Number) return null;
        return v.TryGetInt32(out var i) ? i : null;
    }

    public static List<string> GetStringArray(IDictionary<string, JsonElement>? args, string key)
    {
        var list = new List<string>();
        if (args is null || !args.TryGetValue(key, out var v) || v.ValueKind != JsonValueKind.Array) return list;
        foreach (var e in v.EnumerateArray())
        {
            if (e.ValueKind == JsonValueKind.String) list.Add(e.GetString() ?? "");
        }
        return list;
    }
}
