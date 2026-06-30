-- cvar_set: set a ConVar, wait for it to settle, and report the actual stabilized value.
-- The write-half of the cvar pair (cvar_state reads). UNSAFE -- a general convar write is
-- the same escalation as console_cmd (it can flip sv_cheats / sv_allowcslua), so it rides
-- the existing gate; curated *safe* knobs belong ungated in game_set instead.
--
-- Applied via RunConsoleCommand, NOT GetConVar:SetX -- the latter errors on the client for
-- engine-created (FCVAR_ARCHIVE) convars ("attempted to modify ConVar not created by Lua").
-- RunConsoleCommand applies one frame later, so the same-frame read-back is stale; the
-- handler defers and settles on the value STABILISING (not on equalling the request), so a
-- clamped or cheat-blocked write reports the real result (took=false) instead of hanging.

local SETTLE_CAP = 0.5   -- give up waiting for stability after this long; report as-is
local STABLE_DWELL = 0.1 -- value must read unchanged this long to count as settled

-- Numeric-aware equality: "600.0" matches "600", but "high" still matches "high".
local function valuesMatch(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na == nb end
    return a == b
end

MCP:AddFunction({
    id = "cvar_set",
    description = "Set a console variable, wait for it to settle, and report the actual stabilized value. The write-half of the cvar pair (cvar_state reads). Applied via the console (not a Lua setter, which errors on client engine convars), so it takes effect a frame later -- the call defers and settles on the value stabilising, then reports requested vs actual: `took` is false when the convar clamped the value or rejected the write (e.g. a cheat-protected convar without sv_cheats), `changed` whether it differs from before. `value` is a string (pass numbers/bools as their string form, e.g. \"100\", \"1\"). For curated, safe testing knobs prefer game_set; this is the general escape hatch. Runs in both realms -- set client convars via _cl, server or replicated convars via _sv.",
    requires = { "unsafe" },
    schema = {
        type = "object",
        properties = {
            name = {
                type = "string",
                description = "ConVar name to set (e.g. \"sv_gravity\", \"host_timescale\").",
            },
            value = {
                type = "string",
                description = "New value as a string. Numbers and booleans are passed in their string form (e.g. \"800\", \"0.5\", \"1\").",
            },
        },
        required = { "name", "value" },
    },
    handler = function(args, ctx)
        args = args or {}
        local name = args.name
        if type(name) ~= "string" or name == "" then
            return { ok = false, error = "`name` must be a non-empty convar name" }
        end
        if type(args.value) ~= "string" then
            return { ok = false, error = "`value` must be a string (e.g. \"100\")" }
        end

        local cv = GetConVar(name)
        if not cv then
            return { ok = false, error = "no convar named '" .. name .. "' (use console_cmd for console commands)" }
        end

        local requested = args.value
        local before = cv:GetString()
        RunConsoleCommand(name, requested)

        -- Settle on stability: the value reads the same as last frame for the dwell. This
        -- waits out the one-frame-deferred apply AND any clamping, rather than waiting for
        -- the value to equal the request (which never comes if it clamped/was rejected).
        local lastVal
        MCP:Settle({
            seconds = SETTLE_CAP,
            stable_for = STABLE_DWELL,
            check = function()
                local cur = cv:GetString()
                local stable = lastVal ~= nil and cur == lastVal
                lastVal = cur
                return stable
            end,
        }, function(s)
            local settled = cv:GetString()
            ctx.respond({
                ok = true,
                realm = MCP.util.RealmName(),
                name = name,
                requested = requested,
                before = before,
                value = settled,
                int = cv:GetInt(),
                float = cv:GetFloat(),
                bool = cv:GetBool(),
                took = valuesMatch(settled, requested),
                changed = settled ~= before,
                stabilized = s.settled,
            })
        end)

        return ctx.deferred
    end,
})
