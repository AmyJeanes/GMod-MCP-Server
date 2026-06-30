-- debug_clear: janitor for the debug_* family. Removes every hook the debug_* tools
-- installed in this realm -- debug_record sampling hooks (and, later, debug_draw render
-- hooks), all under the `mcp_debug_` id namespace. For orphans: a recording whose host
-- crashed or reloaded mid-window, or a persistent draw you're done with.
--
-- Ungated even though debug_record/debug_draw need `unsafe`: tearing down hooks the
-- debug_* tools themselves installed is always safe, and cleanup must stay available
-- without the grant. Both realms -- each clears its own realm's hooks (hooks are realm-local).

local PREFIX = "mcp_debug_"

MCP:AddFunction({
    id = "debug_clear",
    description = "Remove every hook the debug_* tools installed in this realm -- debug_record sampling hooks and (later) debug_draw render hooks, all under the `mcp_debug_` id namespace. The janitor for orphans: a recording whose host crashed or was reloaded mid-window, or a persistent draw you are done with. Enumerates hook.GetTable() and removes matching ids, returning the count and the {event, id} list removed (an empty list is a fine no-op). Ungated -- tearing down hooks the debug_* tools themselves installed is always safe, so cleanup stays available even without the unsafe grant those tools need. Runs in both realms; each clears only its own realm's hooks.",
    schema = { type = "object" },
    handler = function()
        -- Collect first, then remove: hook.Remove mutates the table hook.GetTable() returns.
        local found = {}
        for event, hooks in pairs(hook.GetTable()) do
            for id in pairs(hooks) do
                if isstring(id) and string.sub(id, 1, #PREFIX) == PREFIX then
                    found[#found + 1] = { event = event, id = id }
                end
            end
        end
        for _, h in ipairs(found) do
            hook.Remove(h.event, h.id)
        end
        return {
            ok = true,
            realm = MCP.util.RealmName(),
            removed_count = #found,
            removed = found,
        }
    end,
})
