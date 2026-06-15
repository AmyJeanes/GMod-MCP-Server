-- In-game level change requested by the host (host_changelevel, via the
-- bridge-internal `_changelevel`). A map command tears down and rebuilds the
-- server Lua state, so this can't be a deferred handler — instead it mirrors the
-- host_launch bootstrap: set MCP._bootstrap_pending, drop a disk marker so the
-- fresh state keeps reporting "pending" until its first InitPostEntity, then let
-- the .NET host poll _ping for readiness. Shares the MCP._bootstrap_pending flag
-- with sv_launch_intent.lua (which loads first and runs its own eager check).

if not SERVER then return end

local MARKER = "mcp/level_change.json"
local CLEAR_HOOK = "MCP_LevelChange_Clear"
local FALLBACK_HOOK = "MCP_LevelChange_Fallback"

-- Fresh boot after the map command: a marker on disk means we're mid-transition,
-- so keep bootstrap_pending true until InitPostEntity confirms the new map is up.
MCP._bootstrap_pending = MCP._bootstrap_pending
    or (not game.IsDedicated() and file.Exists(MARKER, "DATA"))

hook.Add("InitPostEntity", CLEAR_HOOK, function()
    hook.Remove("InitPostEntity", CLEAR_HOOK)
    if file.Exists(MARKER, "DATA") then
        file.Delete(MARKER)
        MCP._bootstrap_pending = false
    end
end)

-- Invoked from the bridge (_changelevel). Returns its response synchronously; the
-- actual map command runs at end of frame, after the response file is written.
function MCP:RequestLevelChange(args)
    args = args or {}

    if not GetConVar("mcp_enable"):GetBool() then
        return { ok = false, error = "MCP bridge is disabled. In the GMod console, run `mcp_enable 1` to allow level changes." }
    end

    local map = tostring(args.map or "")
    if map == "" then
        return { ok = false, error = "missing `map` argument" }
    end
    if not MCP.util.MapExists(map) then
        return { ok = false, error = string.format("map '%s' not found (no maps/%s.bsp)", map, map) }
    end

    local gamemode = args.gamemode and tostring(args.gamemode) or nil
    local hardReset = args.hard_reset and true or false

    -- New transition: clear any stale launch error so _ping won't report it.
    MCP._bootstrap_error = nil
    MCP._bootstrap_pending = true
    file.Write(MARKER, MCP.util.JsonEncode({ target_map = map }, false))

    -- A gamemode switch only takes effect on a full server (re)start, so force a
    -- `map` load when one is requested; otherwise a soft `changelevel` suffices.
    if gamemode then
        RunConsoleCommand("gamemode", gamemode)
    end
    local cmd = (hardReset or gamemode) and "map" or "changelevel"
    game.ConsoleCommand(cmd .. " " .. map .. "\n")

    -- Safety net: if no teardown happens (command silently refused), release the
    -- pending flag so the host doesn't wait its full timeout. Think + RealTime
    -- because timer.Simple stalls during map loads/pauses. On the happy path the
    -- state is torn down before this fires, taking the hook with it.
    local started = RealTime()
    hook.Add("Think", FALLBACK_HOOK, function()
        if not MCP._bootstrap_pending then
            hook.Remove("Think", FALLBACK_HOOK)
            return
        end
        if (RealTime() - started) >= 30 then
            hook.Remove("Think", FALLBACK_HOOK)
            if file.Exists(MARKER, "DATA") then file.Delete(MARKER) end
            MCP._bootstrap_pending = false
            MCP._bootstrap_error = string.format("level change to '%s' did not start within 30s", map)
        end
    end)

    return { ok = true, map = map, command = cmd }
end
