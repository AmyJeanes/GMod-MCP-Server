-- debug_hooks: inspect the hook registry -- "did my hook register, and where is it defined?"
-- Reads hook.GetTable(); with a filter it returns each match's source file + line via
-- debug.getinfo, else a per-event census. Installs nothing; ungated read. Part of the
-- debug_* family but distinct from debug_clear (which only sweeps mcp_debug_* hooks) -- this
-- inspects ANY hook.

local DEFAULT_LIMIT = 100
local MAX_LIMIT = 500
local CENSUS_CAP = 300

MCP:AddFunction({
    id = "debug_hooks",
    description = "Inspect the hook registry -- answer \"did my hook register, and where is it defined?\" without hand-dumping hook.GetTable(). With `event` and/or `name` it returns matching hooks each with their source file + line (debug.getinfo) -- the fast way to confirm a hook installed and find where. With neither it returns a census: every event with a live hook and its count (sorted by count). `event` restricts to one hook event (e.g. \"Think\", \"PlayerSpawn\"); `name` is a case-insensitive substring filter on the hook identifier. Only hook.Add-registered hooks appear (engine GM: gamemode methods don't); a hook keyed by a Panel/Entity (auto-gc hooks) shows its tostring with is_string_name=false. Installs nothing. Server and client realms have separate registries. `limit` caps the returned list (default 100, max 500).",
    schema = {
        type = "object",
        properties = {
            event = { type = "string", description = "Restrict to this hook event, e.g. \"Think\", \"PlayerSpawn\". Omit (with no name) for a per-event census." },
            name = { type = "string", description = "Case-insensitive substring filter on the hook identifier. Providing this (or event) switches to detail mode with source+line." },
            include_source = { type = "boolean", description = "In detail mode, resolve each hook's source file + line via debug.getinfo (default true)." },
            limit = { type = "integer", minimum = 1, maximum = MAX_LIMIT, description = "Max hooks/events in the returned list (default 100)." },
        },
        required = {},
    },
    handler = function(args)
        args = args or {}
        local eventFilter = args.event
        if eventFilter ~= nil and type(eventFilter) ~= "string" then return { ok = false, error = "`event` must be a hook event name string" } end
        local nameFilter = args.name
        if nameFilter ~= nil and type(nameFilter) ~= "string" then return { ok = false, error = "`name` must be a string" } end
        local limit = math.Clamp(math.floor(tonumber(args.limit) or DEFAULT_LIMIT), 1, MAX_LIMIT)
        local includeSource = args.include_source
        if includeSource == nil then includeSource = true end

        local tbl = hook.GetTable()
        local detail = (eventFilter ~= nil and eventFilter ~= "") or (nameFilter ~= nil and nameFilter ~= "")

        if not detail then
            local events = {}
            local totalHooks = 0
            for ev, hooks in pairs(tbl) do
                local c = table.Count(hooks)
                totalHooks = totalHooks + c
                events[#events + 1] = { event = ev, count = c }
            end
            table.sort(events, function(a, b)
                if a.count ~= b.count then return a.count > b.count end
                return tostring(a.event) < tostring(b.event)
            end)
            local totalEvents = #events
            local truncated = false
            if #events > CENSUS_CAP then
                local trimmed = {}
                for i = 1, CENSUS_CAP do trimmed[i] = events[i] end
                events = trimmed
                truncated = true
            end
            return {
                ok = true, realm = MCP.util.RealmName(), mode = "census",
                total_events = totalEvents, total_hooks = totalHooks,
                events = events, events_truncated = truncated,
            }
        end

        local needle = nameFilter and string.lower(nameFilter) or nil
        local matched = 0
        local rows = {}
        for ev, hooks in pairs(tbl) do
            if eventFilter == nil or eventFilter == "" or ev == eventFilter then
                for id, fn in pairs(hooks) do
                    local isStr = isstring(id)
                    local idStr = isStr and id or tostring(id)
                    if needle == nil or string.find(string.lower(idStr), needle, 1, true) then
                        matched = matched + 1
                        if #rows < limit then
                            local row = { event = ev, name = idStr, is_string_name = isStr }
                            if includeSource and isfunction(fn) then
                                local ok, info = pcall(debug.getinfo, fn, "S")
                                if ok and info then
                                    row.source = info.short_src
                                    row.line = info.linedefined
                                end
                            end
                            rows[#rows + 1] = row
                        end
                    end
                end
            end
        end
        return {
            ok = true, realm = MCP.util.RealmName(), mode = "detail",
            event = (eventFilter ~= nil and eventFilter ~= "") and eventFilter or nil,
            name = nameFilter,
            matched = matched, returned = #rows, truncated = matched > #rows,
            hooks = rows,
        }
    end,
})
