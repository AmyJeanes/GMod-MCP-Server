-- Client side of the two-stage launch handshake.
--
-- The server can't tell which workshop addons the user has *intentionally*
-- disabled — those stay `downloaded=true mounted=false` forever, so a
-- count comparison on the server side would never balance. The client
-- has `steamworks.ShouldMountAddon`, which returns the user's enabled/
-- disabled preference, and that's what makes a deterministic "all
-- enabled addons are mounted" signal possible.
--
-- We compute (expected = downloaded ∧ should-mount, current = mounted),
-- watch for current to reach expected, then notify the server with one
-- `MCP_WorkshopReady` net message. The server fires the map transition
-- on receipt — no debounce, no polling on the server, no plateau timer.

if not CLIENT then return end

local HOOK_ID = "MCP_LaunchIntent_ClientWatch"
local SENT = false

-- A subscribed workshop addon is "expected" to mount if the user hasn't
-- disabled it via the addon manager AND Steam has finished downloading it.
-- Non-workshop addons (loose `addons/` folders, gamemodes etc.) sometimes
-- appear in engine.GetAddons() with no wsid; treat them as enabled by
-- default — they don't have a manager toggle.
local function isExpected(addon)
    if not addon.downloaded then return false end
    local wsid = addon.wsid
    if not wsid or wsid == "" or wsid == "0" then return true end
    return steamworks.ShouldMountAddon(wsid)
end

local function workshopState()
    local expected, current = 0, 0
    for _, addon in ipairs(engine.GetAddons() or {}) do
        if isExpected(addon) then
            expected = expected + 1
            if addon.mounted then current = current + 1 end
        end
    end
    return expected, current
end

hook.Add("Think", HOOK_ID, function()
    if SENT then
        hook.Remove("Think", HOOK_ID)
        return
    end

    local expected, current = workshopState()
    if current < expected then return end

    SENT = true
    hook.Remove("Think", HOOK_ID)

    net.Start("MCP_WorkshopReady")
    net.WriteUInt(current, 16)
    net.WriteUInt(expected, 16)
    net.SendToServer()
end)
