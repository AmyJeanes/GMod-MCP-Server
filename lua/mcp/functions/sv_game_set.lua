-- game_set: curated, typed, range-clamped writer for the handful of safe server-tuning knobs
-- (gravity, timescale, phys_timescale, fakelag). The write-half paired with game_state.
--
-- UNGATED on purpose -- and that is exactly why it exists alongside the unsafe cvar_set. A
-- general convar write is console_cmd-equivalent power (it can flip sv_cheats / sv_allowcslua),
-- so cvar_set rides the unsafe gate; game_set can only set these whitelisted convars within
-- clamped ranges, so it cannot escalate and stays ungated. It NEVER flips sv_cheats: a
-- cheat-protected knob (timescale/fakelag) with sv_cheats off just reports took=false rather
-- than silently enabling cheats.
--
-- Applied via RunConsoleCommand (one frame deferred; engine convars reject :SetX), then
-- settled on the value stabilising (MCP:Settle, like cvar_set) so a clamp or cheat-block is
-- reported honestly (took=false) instead of hanging. Optional restore_after auto-reverts each
-- changed knob to its prior value after N seconds, fire-and-forget: the call returns
-- immediately and the revert runs in the background on RunFor. A later game_set on the same
-- knob cancels a pending revert (last-write-wins) so reverts can't pile up.

local SETTLE_CAP = 0.5    -- give up waiting for stability after this long; report as-is
local STABLE_DWELL = 0.1  -- value must read unchanged this long to count as settled
local MAX_RESTORE = 60    -- RunFor hard-clamps to 60s; keep restore_after within it

-- Knob values are numeric; compare with a small epsilon so a string round-trip can't
-- false-report took=false (e.g. "0.2" -> 0.2).
local function approx(a, b) return math.abs(a - b) < 1e-3 end

MCP:AddFunction({
    id = "game_set",
    requires = { "world_control" },
    description = "Set one or more curated, safe server-tuning knobs, wait for them to settle, and report the actual values. The write-half paired with game_state. Ungated and typed -- it is the safe front for the common testing knobs, vs the unsafe general cvar_set: gravity (sv_gravity), timescale (host_timescale -- scales the whole clock), phys_timescale (physics-only time scale), fakelag (net_fakelag, simulated lag in ms). Supply any subset (at least one); each is clamped to a safe range (a clamp is reported via clamped_from). Per knob it reports requested/before/value/took/changed: `took` is false when the value clamped or was rejected. `timescale` and `fakelag` are cheat-protected -- game_set never flips sv_cheats, so with it off they report took=false (use phys_timescale, which needs no cheats; to enable cheats, type `sv_cheats 1` in the in-game console or relaunch with host_launch `cheats=true` -- sv_cheats can't be flipped from the bridge). Optional `restore_after` auto-reverts every knob changed by this call to its prior value after that many seconds (max 60), fire-and-forget: the call returns now and the revert runs in the background; a later game_set on the same knob cancels the pending revert.",
    schema = {
        type = "object",
        properties = {
            gravity = {
                type = "number",
                description = "World gravity (sv_gravity), default 600. Clamped 0-10000. Not cheat-protected.",
            },
            timescale = {
                type = "number",
                description = "Clock prescale (host_timescale): <1 = slow-motion, >1 = fast-forward, scaling animation/think/physics. Clamped 0.01-10. Cheat-protected (needs sv_cheats, else took=false).",
            },
            phys_timescale = {
                type = "number",
                description = "Physics-only time scale (phys_timescale). Clamped 0.01-10. NOT cheat-protected, so it works without sv_cheats -- but only affects physics, not animation/think.",
            },
            fakelag = {
                type = "number",
                description = "Simulated network lag in milliseconds (net_fakelag). Clamped 0-1000. Cheat-protected (needs sv_cheats, else took=false).",
            },
            restore_after = {
                type = "number",
                description = "Auto-revert every knob changed by this call to its prior value after this many seconds (max 60), fire-and-forget. Omit to leave the changes in place.",
            },
        },
    },
    handler = function(args, ctx)
        args = args or {}
        MCP._gameRestores = MCP._gameRestores or {} -- convar -> token of the owning pending revert

        local requested = {}
        local count = 0
        for name, def in pairs(MCP.game.KNOBS) do
            if args[name] ~= nil then
                local raw = tonumber(args[name])
                if not raw then return { ok = false, error = "`" .. name .. "` must be a number" } end
                local cv = GetConVar(def.convar)
                if not cv then return { ok = false, error = "convar '" .. def.convar .. "' not found" } end
                requested[name] = { def = def, cv = cv, value = math.Clamp(raw, def.min, def.max), raw = raw }
                count = count + 1
            end
        end
        if count == 0 then
            return { ok = false, error = "specify at least one knob: gravity, timescale, phys_timescale, fakelag" }
        end

        local restoreAfter = tonumber(args.restore_after)
        if restoreAfter then
            if restoreAfter <= 0 then restoreAfter = nil else restoreAfter = math.min(restoreAfter, MAX_RESTORE) end
        end

        -- Apply: capture the prior value, drop any pending revert for this knob (last-write-wins),
        -- then write via the console (applies one frame later).
        for _, item in pairs(requested) do
            item.before = item.cv:GetFloat()
            MCP._gameRestores[item.def.convar] = nil
            RunConsoleCommand(item.def.convar, tostring(item.value))
        end

        -- Settle on every requested knob reading the same as last frame (waits out the
        -- one-frame apply and any clamp/cheat-reject), then report the real result.
        local lastVals
        MCP:Settle({
            seconds = SETTLE_CAP,
            stable_for = STABLE_DWELL,
            check = function()
                local stable = lastVals ~= nil
                local cur = {}
                for name, item in pairs(requested) do
                    local v = item.cv:GetFloat()
                    cur[name] = v
                    if lastVals and lastVals[name] ~= v then stable = false end
                end
                lastVals = cur
                return stable
            end,
        }, function(s)
            local knobs = {}
            local restoreTo = {}
            for name, item in pairs(requested) do
                local final = item.cv:GetFloat()
                local res = {
                    convar = item.def.convar,
                    requested = item.value,
                    before = item.before,
                    value = final,
                    took = approx(final, item.value),
                    changed = not approx(final, item.before),
                }
                if item.raw ~= item.value then res.clamped_from = item.raw end
                if item.def.cheat and not res.took then
                    res.note = "cheat-protected; needs sv_cheats 1, which is blocklisted from Lua -- enable it in the in-game console or relaunch with host_launch cheats=true (sv_cheats left unchanged)"
                end
                knobs[name] = res
                restoreTo[name] = item.before
            end

            local result = {
                ok = true,
                realm = MCP.util.RealmName(),
                stabilized = s.settled,
                knobs = knobs,
            }

            -- Fire-and-forget revert: claim ownership per convar with a unique token; the
            -- background RunFor reverts a knob only if it still owns it (a later game_set on
            -- that knob clears the entry, so a superseded revert no-ops). Runs after the
            -- response, so the call returns immediately.
            if restoreAfter then
                local token = {}
                for _, item in pairs(requested) do
                    MCP._gameRestores[item.def.convar] = token
                end
                result.restore = { after_seconds = restoreAfter, to = restoreTo }
                ctx.respond(result)

                MCP:RunFor({ seconds = restoreAfter }, function()
                    for _, item in pairs(requested) do
                        if MCP._gameRestores[item.def.convar] == token then
                            RunConsoleCommand(item.def.convar, tostring(item.before))
                            MCP._gameRestores[item.def.convar] = nil
                        end
                    end
                end)
                return
            end

            ctx.respond(result)
        end)

        return ctx.deferred
    end,
})
