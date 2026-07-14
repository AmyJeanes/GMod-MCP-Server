-- Free-camera PVS support for the screenshot tool (functions/cl_screenshot.lua).
--
-- A free camera renders from a spot the player may not be able to see, but the
-- engine only keeps entities inside the PLAYER's PVS un-dormant, so anything the
-- camera looks at that's outside it is dormant and renders missing (world-portal
-- surfaces especially). The client sends the camera origin; the server adds it to
-- the host's PVS each tick (the AddOriginToPVS trick world-portals uses for its
-- exit origins), un-dormanting everything in visleafs visible from the camera.
--
-- The client must not capture until that has actually reached it. A fixed settle
-- can't be right for every host - a frozen or high-ping host propagates far
-- slower than a live one - so the server also computes the drawable entities the
-- extension will un-dormant and sends their indices back; the client holds the
-- shot until every one is live client-side. That is a real done-condition, not a
-- guessed delay. Non-drawable and nodraw entities are excluded: they never
-- render, and can stay absent on the client, which would stall the wait.
--
-- Only a non-code signal ever crosses realms (client->server: a Vector + a clear
-- flag, host-gated; server->client: a list of entity indices), so this never
-- breaches the client->server no-code rule (see sh_irec_net.lua). Lives in
-- libraries/ (not functions/) so the headless README tool-list generator never
-- runs net at load, the same reason sh_irec_net.lua and sh_luarun_net.lua sit here.

MCP.screenshotPVS = MCP.screenshotPVS or {}

local MSG_EXTEND = "mcp_screenshot_pvs"          -- client -> server: extend / release
local MSG_TARGETS = "mcp_screenshot_pvs_targets" -- server -> client: indices to await

if SERVER then
    util.AddNetworkString(MSG_EXTEND)
    util.AddNetworkString(MSG_TARGETS)

    -- [ply] = { origin = Vector, expire = RealTime seconds }. Short TTL so a
    -- crashed or abandoned capture can't pin the extension on indefinitely.
    MCP._screenshotPVSAdds = MCP._screenshotPVSAdds or {}
    local pvsAdds = MCP._screenshotPVSAdds

    -- Drawable entities in `origin`'s PVS the player doesn't already have - exactly
    -- the set AddOriginToPVS(origin) un-dormants, so exactly what the client must
    -- wait to arrive. Non-drawable (no model) and nodraw entities are skipped:
    -- they don't render, and can stay absent on the client, which would stall the
    -- wait. Static brushwork is kept - a never-seen area's geometry is genuinely
    -- absent client-side until it streams in.
    ---@param ply Player
    ---@param origin Vector
    ---@return integer[]
    local function computeTargets(ply, origin)
        local targets = {}
        for _, e in ipairs(ents.FindInPVS(origin)) do
            if IsValid(e) and e ~= ply and not e:IsPlayer() then
                local m = e:GetModel()
                if m and m ~= "" and not e:GetNoDraw() and not ply:TestPVS(e) then
                    targets[#targets + 1] = e:EntIndex()
                end
            end
        end
        return targets
    end

    net.Receive(MSG_EXTEND, function(_, ply)
        if not (IsValid(ply) and ply:IsListenServerHost()) then return end
        if net.ReadBool() then
            pvsAdds[ply] = nil
            return
        end
        local origin = net.ReadVector()
        pvsAdds[ply] = { origin = origin, expire = RealTime() + 10 }

        local targets = computeTargets(ply, origin)
        net.Start(MSG_TARGETS)
        net.WriteUInt(#targets, 16)
        for _, idx in ipairs(targets) do
            net.WriteUInt(idx, 16)
        end
        net.Send(ply)
    end)

    hook.Add("SetupPlayerVisibility", "MCP_ScreenshotPVS", function(ply)
        local add = pvsAdds[ply]
        if not add then return end
        if RealTime() >= add.expire then
            pvsAdds[ply] = nil
            return
        end
        AddOriginToPVS(add.origin)
    end)
else
    ---@class MCP.ScreenshotPVSWait
    ---@field targets integer[]|nil  -- nil until the server's index list arrives

    net.Receive(MSG_TARGETS, function()
        local n = net.ReadUInt(16)
        local t = {}
        for _ = 1, n do t[#t + 1] = net.ReadUInt(16) end
        local w = MCP.screenshotPVS._active
        if w then w.targets = t end
    end)

    -- Extend the host PVS to `origin` and start collecting the target set. Only
    -- one capture runs at a time, so a single in-flight wait is enough.
    ---@param origin Vector
    ---@return MCP.ScreenshotPVSWait
    function MCP.screenshotPVS.Begin(origin)
        local w = { targets = nil }
        MCP.screenshotPVS._active = w
        net.Start(MSG_EXTEND)
        net.WriteBool(false)
        net.WriteVector(origin)
        net.SendToServer()
        return w
    end

    -- Target entities not yet live (valid + non-dormant). Returns nil while the
    -- server's list is still in flight (keep waiting); otherwise the still-pending
    -- indices (empty table = ready).
    ---@param w MCP.ScreenshotPVSWait?
    ---@return integer[]|nil
    function MCP.screenshotPVS.Pending(w)
        if not w or not w.targets then return nil end
        local pending = {}
        for _, idx in ipairs(w.targets) do
            local e = Entity(idx)
            if not (IsValid(e) and not e:IsDormant()) then
                pending[#pending + 1] = idx
            end
        end
        return pending
    end

    -- Stop extending the host PVS.
    ---@param w MCP.ScreenshotPVSWait?
    function MCP.screenshotPVS.Finish(w)
        if MCP.screenshotPVS._active == w then MCP.screenshotPVS._active = nil end
        net.Start(MSG_EXTEND)
        net.WriteBool(true)
        net.SendToServer()
    end
end
