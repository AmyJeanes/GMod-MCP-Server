using System.Text.Json;
using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

/// <summary>
/// Explicit read of GMod's engine console log (console.log) — the raw, unfiltered
/// tail. In-process, ungated (read-only file access), works even when the bridge is
/// down. The curated-warning subset also rides passively on other tool results'
/// <c>engine_events</c>; this is the "give me everything" counterpart.
/// </summary>
public sealed class EngineLogTool : IHostTool
{
    private const int MaxLimit = 2000;
    private readonly EngineLog _log;

    public EngineLogTool(EngineLog log) => _log = log;

    public string Name => "engine_log";

    public string Description =>
        "Read the tail of GMod's engine console log (console.log) — the engine-native C++ output the Lua " +
        "console_read tools structurally cannot see: physics/transform warnings (`Bad SetLocalOrigin`, " +
        "`Crazy origin on entity`), asset/mount spew, engine errors. Returns the raw unfiltered tail; the " +
        "curated serious warnings also ride passively on other tool results' `engine_events`. Needs GMod " +
        "launched with `-condebug` (host_launch adds it automatically; or set it in your Steam launch " +
        "options) — returns enabled=false with a hint otherwise. Pass `since` (a `cursor` from a previous " +
        "call) for only newer lines; omit for the recent tail. Read-only, no capability required.";

    public JsonElement InputSchema { get; } = HostToolHelpers.ParseSchema("""
    {
      "type": "object",
      "properties": {
        "since":  { "type": "integer", "description": "Byte cursor from a previous call's `cursor`; returns only lines written since. Omit to return the recent tail." },
        "limit":  { "type": "integer", "description": "Max lines to return, keeping the most recent (default 200, max 2000)." },
        "filter": { "type": "string",  "description": "Only return lines containing this substring (case-insensitive). Applied after the tail/since selection." }
      },
      "required": []
    }
    """);

    public ValueTask<CallToolResult> InvokeAsync(IDictionary<string, JsonElement>? args, CancellationToken ct)
    {
        long since = -1;
        if (args is not null && args.TryGetValue("since", out var sv)
            && sv.ValueKind == JsonValueKind.Number && sv.TryGetInt64(out var sl))
        {
            since = sl;
        }
        var limit = Math.Clamp(HostToolHelpers.GetInt(args, "limit", 200), 1, MaxLimit);
        var filter = HostToolHelpers.GetString(args, "filter", "");

        var res = _log.Read(since, limit, string.IsNullOrEmpty(filter) ? null : filter);

        var arr = new JsonArray();
        foreach (var line in res.Lines) arr.Add(line);

        var obj = new JsonObject
        {
            ["ok"] = true,
            ["enabled"] = res.Present,
            ["path"] = res.Path,
            ["lines"] = arr,
            ["cursor"] = res.Cursor,
            ["dropped"] = res.Dropped,
        };
        if (!res.Present)
        {
            obj["note"] =
                "No console.log — engine output isn't being captured. Relaunch via host_launch (it adds "
                + "-condebug), or add -condebug to your Steam launch options.";
        }

        return ValueTask.FromResult(HostToolHelpers.Ok(obj.ToJsonString()));
    }
}
