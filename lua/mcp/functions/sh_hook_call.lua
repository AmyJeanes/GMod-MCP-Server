-- hook_call: dispatch a GMod hook and report what it returns / which handler vetoes it.
-- The write-side companion to debug_hooks (which only inspects the registry): here you actually
-- FIRE a hook -- e.g. an addon's veto/filter hook (wp-shouldtp, wp-shouldrender, GM:PlayerSpawn)
-- -- with structured args and read back the result, instead of hand-rolling hook.Call in lua_run.
--
-- unsafe: firing an arbitrary hook can trigger real gameplay side effects (every registered
-- handler runs), the same power as lua_run's RunConsoleCommand reach -- so it rides the unsafe gate.

-- Resolve one structured arg to a Lua value. A plain scalar (number/string/bool) passes straight
-- through; an object selects a constructor: {entindex=N} -> Entity, {vector=[x,y,z]} -> Vector,
-- {angle=[p,y,r]} -> Angle. Anything else passes as-is.
-- Coerces an arbitrary JSON-decoded hook arg (scalar or {entindex/vector/angle=...}).
---@param a any
local function resolveArg(a)
    if type(a) ~= "table" then return a end
    if a.entindex ~= nil then return Entity(tonumber(a.entindex) or -1) end
    if a.vector ~= nil and istable(a.vector) then
        return Vector(tonumber(a.vector[1]) or 0, tonumber(a.vector[2]) or 0, tonumber(a.vector[3]) or 0)
    end
    if a.angle ~= nil and istable(a.angle) then
        return Angle(tonumber(a.angle[1]) or 0, tonumber(a.angle[2]) or 0, tonumber(a.angle[3]) or 0)
    end
    return a
end

---@param list table?
local function resolveArgs(list)
    local out, n = {}, 0
    if istable(list) then
        local arr = list --[[@as table]] -- istable() already confirmed non-nil; custom predicate, analyzer can't narrow it
        n = #arr
        for i = 1, n do out[i] = resolveArg(arr[i]) end
    end
    return out, n
end

MCP:AddFunction({
    id = "hook_call",
    description = "Fire a GMod hook and report the result -- the dispatch companion to debug_hooks (which only reads the registry). Use it to test an addon's veto/filter hooks (e.g. \"wp-shouldtp\", \"wp-shouldrender\", \"wp-shouldclone\", or an engine hook like \"PlayerSpawn\") without hand-rolling hook.Call in lua_run. `name` is the hook event. `args` is a positional array passed to the handlers: each item is a plain scalar (number/string/bool passed as-is) OR an object selecting a type -- {\"entindex\":N} -> that Entity, {\"vector\":[x,y,z]} -> Vector, {\"angle\":[p,y,r]} -> Angle. By default it runs the real hook.Call(name, GAMEMODE, ...args) and reports `returned` (the first non-nil return, which for a veto hook is the veto value); set `gamemode:false` to pass nil instead of GAMEMODE (skip the GM: method). Set `per_handler:true` to instead invoke each hook.Add handler individually and report every one's return plus `vetoed_by` (the first handler that returned non-nil) and `handler_count` -- the way to see WHICH handler is vetoing (note: this bypasses hook.Call's short-circuit, so all handlers run even past the first veto, and GM: gamemode methods are not included). WARNING: firing a hook runs real handlers and can have gameplay side effects; prefer read-only veto/filter hooks. Server and client realms have separate hook registries -- fire in the realm you care about.",
    schema = {
        type = "object",
        properties = {
            name = { type = "string", description = "Hook event name to fire, e.g. \"wp-shouldtp\" or \"PlayerSpawn\"." },
            args = { type = "array", description = "Positional args for the handlers. Each item: a scalar (number/string/bool, passed as-is), or an object {entindex:N} / {vector:[x,y,z]} / {angle:[p,y,r]} to build an Entity/Vector/Angle." },
            gamemode = { type = "boolean", description = "Pass GAMEMODE as hook.Call's 2nd arg (also fires the GM: method). Default true; false passes nil. Ignored in per_handler mode." },
            per_handler = { type = "boolean", description = "Invoke each registered hook.Add handler individually and report each one's return + vetoed_by, instead of a single hook.Call. Reveals which handler vetoes (runs ALL handlers, no short-circuit; excludes GM: methods)." },
        },
        required = { "name" },
    },
    requires = { "unsafe" },
    ---@param args table
    handler = function(args)
        args = args or {}
        if type(args.name) ~= "string" or args.name == "" then
            return { ok = false, error = "`name` must be a non-empty hook event name" }
        end
        if args.args ~= nil and not istable(args.args) then
            return { ok = false, error = "`args` must be an array of positional hook arguments" }
        end

        local resolved, n = resolveArgs(args.args)
        local realm = MCP.util.RealmName()

        if args.per_handler == true then
            local tbl = hook.GetTable()[args.name]
            local handlers = {}
            local vetoedBy = nil
            if istable(tbl) then
                for id, fn in pairs(tbl) do
                    if isfunction(fn) then
                        local isStr = isstring(id)
                        local ok, ret = pcall(fn, unpack(resolved, 1, n))
                        local row = { id = isStr and id or tostring(id), is_string_name = isStr }
                        if not ok then
                            row.errored = true
                            row.error = tostring(ret)
                        else
                            row.returned = MCP.util.Serialize(ret)
                            if ret ~= nil and vetoedBy == nil then vetoedBy = row.id end
                        end
                        handlers[#handlers + 1] = row
                    end
                end
            end
            return {
                ok = true,
                realm = realm,
                name = args.name,
                mode = "per_handler",
                handler_count = #handlers,
                vetoed_by = vetoedBy,
                handlers = handlers,
            }
        end

        local gm = (args.gamemode == false) and nil or (GAMEMODE or GM)
        local ok, ret = pcall(hook.Call, args.name, gm, unpack(resolved, 1, n))
        if not ok then
            return { ok = false, realm = realm, name = args.name, error = "hook.Call errored: " .. tostring(ret) }
        end
        return {
            ok = true,
            realm = realm,
            name = args.name,
            mode = "call",
            with_gamemode = args.gamemode ~= false,
            arg_count = n,
            returned = MCP.util.Serialize(ret),
        }
    end,
})
