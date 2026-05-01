using System.Text.Json;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host;

internal static class HostToolHelpers
{
    public static JsonElement ParseSchema(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.Clone();
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
