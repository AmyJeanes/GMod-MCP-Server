-- Read recently captured passive console output / Lua errors for this realm
-- (sh_capture.lua) on demand. Read-only; gated by mcp_enable like any tool.
-- Same buffer that rides along on tool responses as `events` — this lets the
-- model poll it deliberately (e.g. after starting some async work).

MCP:AddFunction({
    id = "console_read",
    description = "Read recently captured console output and Lua errors that fired outside a tool call (background hooks, timers, autorefresh, other addons) in this realm. Pass `since` (the `cursor` from a previous call) to get only newer events; omit for everything retained.",
    schema = {
        type = "object",
        properties = {
            since = {
                type = "integer",
                description = "Return only events with seq greater than this. Use the `cursor` from a previous call.",
            },
            limit = {
                type = "integer",
                description = "Cap the number of events returned, keeping the most recent.",
            },
        },
    },
    handler = function(args)
        args = args or {}
        local events, cursor, dropped = MCP:DrainEventsSince(args.since)

        local limit = args.limit
        if isnumber(limit) and limit > 0 and #events > limit then
            local n = limit --[[@as number]] -- isnumber() already confirmed non-nil; custom predicate, analyzer can't narrow it
            local trimmed = {}
            for i = #events - n + 1, #events do
                trimmed[#trimmed + 1] = events[i]
            end
            events = trimmed
            dropped = true
        end

        return {
            ok = true,
            events = events,
            cursor = cursor,
            dropped = dropped and true or false,
        }
    end,
})
