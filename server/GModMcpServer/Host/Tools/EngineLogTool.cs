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
        "Read the tail of GMod's engine console log (console.log) — the raw, unfiltered console: " +
        "engine-native C++ output (`Bad SetLocalOrigin`, `Crazy origin`, asset/mount spew, engine errors) " +
        "plus both realms' Lua output, interleaved. Tool results also carry a live unified `events` stream " +
        "from this same log (deduped, in true order, [MCP] noise removed); engine_log is the on-demand raw " +
        "read and includes the boot history the passive stream skips. Needs GMod launched with `-condebug` " +
        "(host_launch adds it; host_status.condebug confirms) — returns enabled=false with a hint otherwise. " +
        "Pass `since` (a `cursor` from a previous call) for only newer lines; omit for the recent tail. " +
        "Filter with a case-insensitive `filter` substring or a structured `kind` " +
        "(`error`/`engine`/`map_change`, classified like the passive stream); both match whole " +
        "logical messages, so a multi-line Lua error comes back intact and `error` excludes benign " +
        "`ErrorAPI:`-style lines a substring would catch. " +
        "Read-only, no capability required.";

    public JsonElement InputSchema { get; } = HostToolHelpers.ParseSchema("""
    {
      "type": "object",
      "properties": {
        "since":  { "type": "integer", "description": "Byte cursor from a previous call's `cursor`; returns only lines written since. Omit to return the recent tail." },
        "limit":  { "type": "integer", "description": "Max lines to return, keeping the most recent (default 200, max 2000). With filter/kind, bounds whole matched messages within that line budget so none is split." },
        "filter": { "type": "string",  "description": "Case-insensitive substring. Returns whole logical messages (header plus indented stack frames / continuation) that contain it — never an orphaned fragment. Applied after the tail/since selection." },
        "kind":   { "type": "string",  "enum": ["error", "engine", "map_change"], "description": "Return only messages of this kind, classified like the passive `events` stream: `error` = real Lua errors (excludes benign `ErrorAPI:`-style lines a substring would catch), `engine` = other engine/Lua output, `map_change` = map-change boundaries. Combine with `filter` to require both." }
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
        var kind = HostToolHelpers.GetString(args, "kind", "");
        if (kind.Length > 0 && kind is not ("error" or "engine" or "map_change"))
        {
            return ValueTask.FromResult(HostToolHelpers.Err(
                $"unknown kind '{kind}'; expected one of error, engine, map_change"));
        }

        var res = _log.Read(since, limit,
            string.IsNullOrEmpty(filter) ? null : filter,
            string.IsNullOrEmpty(kind) ? null : kind);

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
