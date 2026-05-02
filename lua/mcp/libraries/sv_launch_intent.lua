-- Server side of the two-stage launch handler.
--
-- The .NET host_launch tool writes `data/mcp/launch_intent.json` and boots
-- GMod into the stock bootstrap map (gm_construct). Once the listen server
-- is up, this script reads the intent, then waits for the local client to
-- send `MCP_WorkshopReady` (see cl_launch_intent.lua) — the client uses
-- `steamworks.ShouldMountAddon` to compute exactly when every *enabled*
-- workshop subscription has mounted, so detection is deterministic and
-- ignores addons the user has disabled in the addon manager.
--
-- The only timer that remains is `max_wait_seconds`, a safety net for the
-- pathological case where the client never reports ready (no client ever
-- connects, Steam download stalls, etc.) — never used on the happy path.
--
-- On dedicated servers this whole flow is a no-op: dedicated installs use
-- `+workshop_collection_id` to mount before any Lua runs, so there's
-- nothing to wait for, and host_launch doesn't write intent files there
-- anyway. We still register `MCP_WorkshopReady` unconditionally so a
-- client running cl_launch_intent.lua can `net.Start` it without
-- triggering the engine's "unregistered message" warning.

if not SERVER then return end

util.AddNetworkString("MCP_WorkshopReady")

local INTENT_PATH = "mcp/launch_intent.json"
local FALLBACK_HOOK = "MCP_LaunchIntent_Fallback"
local READY_HOOK = "MCP_LaunchIntent_Ready"

local pendingIntent = nil
local fired = false
local startTime = 0

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

local function transition(reason)
    if fired then return end
    fired = true
    hook.Remove("Think", FALLBACK_HOOK)

    local intent = pendingIntent
    pendingIntent = nil
    if not intent then
        MCP._bootstrap_pending = false
        return
    end

    local targetMap = tostring(intent.target_map or "")
    local targetGm = tostring(intent.target_gamemode or "sandbox")
    if targetMap == "" then
        MCP._bootstrap_pending = false
        return
    end

    MsgN(string.format("[MCP] launch intent: %s after %.2fs.",
        reason, RealTime() - startTime))

    -- Always issue a map command, even when target == current. A naked
    -- `ply:Spawn()` doesn't reliably re-precache player models that mounted
    -- after the initial spawn — the engine appears to cache the failed
    -- lookup. A full map reload forces a fresh precache pass and a clean
    -- player spawn with the workshop model in place. The cost is one map
    -- load (~3-5 s) on every host_launch; correctness wins over speed here.
    MsgN(string.format("[MCP] launch intent: %s -> %s (gamemode=%s).",
        game.GetMap(), targetMap, targetGm))
    RunConsoleCommand("gamemode", targetGm)
    RunConsoleCommand("map", targetMap)

    -- Clear bootstrap_pending only after the *target* map has fully loaded.
    -- The map command above kicks off a fresh InitPostEntity once loading
    -- finishes; that's the signal the .NET host waits on.
    hook.Add("InitPostEntity", READY_HOOK, function()
        hook.Remove("InitPostEntity", READY_HOOK)
        MCP._bootstrap_pending = false
    end)
end

net.Receive("MCP_WorkshopReady", function(_, ply)
    if not pendingIntent or fired then return end
    local current = net.ReadUInt(16)
    local expected = net.ReadUInt(16)
    transition(string.format("client signalled workshop ready (%d/%d enabled mounted)",
        current, expected))
end)

hook.Add("InitPostEntity", "MCP_LaunchIntent_Boot", function()
    hook.Remove("InitPostEntity", "MCP_LaunchIntent_Boot")
    if game.IsDedicated() then return end -- dedi mounts via +workshop_collection_id; nothing to do
    pendingIntent = readIntent()
    if not pendingIntent then
        -- Eager-check claimed bootstrap was pending but the file is now gone
        -- or unreadable; clear the flag so _ping doesn't lie.
        MCP._bootstrap_pending = false
        return
    end

    startTime = RealTime()
    local maxWait = math.max(1, tonumber(pendingIntent.max_wait_seconds) or 60)

    -- Safety net: trigger transition anyway if the client never sends
    -- `MCP_WorkshopReady` within max_wait. Driven by Think + RealTime
    -- because timer.Simple is CurTime-based and stalls during pause /
    -- map loads.
    hook.Add("Think", FALLBACK_HOOK, function()
        if fired then
            hook.Remove("Think", FALLBACK_HOOK)
            return
        end
        if (RealTime() - startTime) >= maxWait then
            transition(string.format("max_wait %.0fs elapsed without client signal", maxWait))
        end
    end)
end)
