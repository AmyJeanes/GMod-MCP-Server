-- Server side of the two-stage launch handler.
--
-- The .NET host_launch tool decides BEFORE launch whether the target map is
-- resolvable on disk. Base-game and loose-addon maps are booted directly with
-- `+map` and never reach here. A map that ISN'T on disk is assumed to be a
-- workshop map: the host boots the stock bootstrap map (gm_construct) and
-- writes `data/mcp/launch_intent.json`. Once the listen server is up, this
-- script reads the intent and transitions to the real target.
--
-- No mount-wait handshake is needed: on the branches we target (x86-64 / dev),
-- the engine itself waits for Steam Workshop mounts to finish before a map load
-- completes, so by the time this server's InitPostEntity fires every enabled
-- workshop addon is already mounted. One MapExists check is then authoritative:
--   * present -> the workshop map mounted; changelevel to it.
--   * absent  -> not on disk and didn't mount, so it doesn't exist. Stay on
--                gm_construct and report it as a soft miss (not an error): the
--                launch still succeeds with a usable game.
-- Older pre-fix builds, where mounts trail the load, would false-miss here; we
-- deliberately don't support them (see AGENTS.md).
--
-- On dedicated servers this whole flow is a no-op: dedicated installs mount via
-- `+workshop_collection_id` before any Lua runs, and host_launch doesn't write
-- intent files there anyway.

if not SERVER then return end

local INTENT_PATH = "mcp/launch_intent.json"
local READY_HOOK = "MCP_LaunchIntent_Ready"

-- Eager check: the .NET host writes the intent file *before* spawning gmod.exe,
-- so the bridge can answer "bootstrap pending" correctly even on the very first
-- _ping that arrives before InitPostEntity has fired. Dedicated servers don't
-- run the bootstrap flow, so they always report done.
MCP._bootstrap_pending = (not game.IsDedicated()) and file.Exists(INTENT_PATH, "DATA")

local function readIntent()
    if not file.Exists(INTENT_PATH, "DATA") then return nil end
    local raw = file.Read(INTENT_PATH, "DATA")
    file.Delete(INTENT_PATH) -- single-shot: don't re-fire on subsequent map loads
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, decoded = pcall(util.JSONToTable, raw)
    if not ok or type(decoded) ~= "table" then return nil end
    return decoded
end

hook.Add("InitPostEntity", "MCP_LaunchIntent_Boot", function()
    hook.Remove("InitPostEntity", "MCP_LaunchIntent_Boot")
    if game.IsDedicated() then return end -- dedi mounts via +workshop_collection_id; nothing to do

    local intent = readIntent()
    if not intent then
        -- Eager-check claimed bootstrap was pending but the file is now gone or
        -- unreadable; clear the flag so _ping doesn't lie.
        MCP._bootstrap_pending = false
        return
    end

    local targetMap = tostring(intent.target_map or "")
    local targetGm = tostring(intent.target_gamemode or "sandbox")
    if targetMap == "" then
        MCP._bootstrap_pending = false
        return
    end

    -- Single authoritative check: we're on gm_construct with every enabled
    -- workshop addon already mounted (the engine waited for mounts during this
    -- load), so this sees base-game AND workshop maps. If it's still missing it
    -- genuinely doesn't exist - surface a soft miss and stay put, rather than
    -- issuing a `map` command that would fail silently and hang the host.
    if not MCP.util.MapExists(targetMap) then
        MCP._bootstrap_map_missing = targetMap
        MCP._bootstrap_pending = false
        MsgN(string.format(
            "[MCP] launch intent: target map '%s' not found (not on disk, no mounted workshop addon provides it); staying on %s.",
            targetMap, game.GetMap()))
        return
    end

    -- The workshop map is mounted; changelevel to it. This is a full map load,
    -- so it precaches workshop content (player models etc.) cleanly and the
    -- spawn on the target map has everything in place.
    MsgN(string.format("[MCP] launch intent: %s -> %s (gamemode=%s).",
        game.GetMap(), targetMap, targetGm))
    -- Sentinel the .NET boot scanner keys on to scope the startup log to the FINAL
    -- map: this `map` fires so early the engine drops the player as "(Disconnect by
    -- user.)", not "(Server shutting down)", so the transition has no engine marker
    -- of its own to detect (EngineLogFilter.IsMapChange).
    MsgN("[MCP] map transition")
    RunConsoleCommand("gamemode", targetGm)
    RunConsoleCommand("map", targetMap)

    -- Clear bootstrap_pending only after the *target* map has fully loaded. The
    -- map command above kicks off a fresh InitPostEntity once loading finishes;
    -- that's the signal the .NET host waits on.
    hook.Add("InitPostEntity", READY_HOOK, function()
        hook.Remove("InitPostEntity", READY_HOOK)
        MCP._bootstrap_pending = false
    end)
end)
