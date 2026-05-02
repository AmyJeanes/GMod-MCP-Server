-- Capture a JPEG screenshot and return it as MCP image content so the
-- assistant can see the in-game state directly.
--
-- The capture is always rendered at the requested output resolution
-- (default 1280x720) via `render.RenderView`, regardless of the user's
-- actual screen size. That keeps payloads sane on 1440p / 4K displays —
-- a 2560x1440 native shot is overwhelming when the assistant only needs
-- to read the scene. Side effect: the on-screen view briefly shows the
-- rendered region in the top-left during the capture frame; the engine
-- redraws normally on the next frame.
--
-- Two camera modes:
--   * Player-view (no `origin`/`angles`): camera follows the local
--     player's eye position, angles, and FOV. Viewmodel is drawn so the
--     held weapon is visible. HUD is NOT drawn — RenderView's HUD pass
--     is independent of the rest of the world render and would mis-align
--     with the downscaled output.
--   * Free-camera (`origin`+`angles` set): camera is positioned in world
--     space at the supplied transform; viewmodel hidden, player body
--     visible.
--
-- `render.Capture` (and `render.RenderView`) need an active rendering
-- context, so the handler defers via `ctx.deferred` and resolves from a
-- one-shot `PostRender` hook. A `Think`-based deadline is the fallback
-- when PostRender doesn't fire (window minimised, engine paused, etc.).

local DEFAULT_W, DEFAULT_H = 1280, 720
local DEFAULT_FOV = 90

local function uniqueHookId()
    return "MCP_Screenshot_" .. tostring(SysTime()) .. "_" .. tostring(math.random(1, 1e9))
end

local function parseVec3(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
    if not (x and y and z) then return nil end
    return x, y, z
end

-- Inside a render.RenderView with w/h smaller than the real screen, ScrW()
-- and ScrH() return the *viewport* dimensions, not the screen. Addons that
-- key per-frame render targets off ScrW()/ScrH() (e.g. world-portals'
-- linked_portal_door, which names its RT "portal:<idx>:<scrw>:<scrh>") will
-- therefore look up a *different* RT inside our screenshot than the one the
-- normal frame rendered into — yielding a black portal on the first shot,
-- and a populated one on the second once our own ENT:Draw has primed the
-- viewport-sized RT. Pre-binding each portal's `.texture` to the
-- screenshot-sized RT (and passing width/height in the view so
-- world-portals' wrapper fills it at matching dimensions) keeps both halves
-- in agreement on the very first call. Restored after the render so the
-- next regular frame is undisturbed.
local function primeWorldPortalRTs(outW, outH)
    if not (_G.wp and istable(_G.wp)) then return nil end
    local portals = ents.FindByClass("linked_portal_door")
    if not portals or #portals == 0 then return nil end
    local resCvar = GetConVar("worldportals_resolution_percentage")
    local res = resCvar and (resCvar:GetInt() / 100) or 1
    local rtW = math.max(1, math.floor(outW * res))
    local rtH = math.max(1, math.floor(outH * res))
    local saved = {}
    for _, portal in ipairs(portals) do
        if IsValid(portal) then
            local name = "portal:" .. portal:EntIndex() .. ":" .. rtW .. ":" .. rtH
            local rt = GetRenderTarget(name, rtW, rtH)
            if rt then
                saved[#saved + 1] = { portal = portal, prev = portal:GetTexture() }
                portal:SetTexture(rt)
            end
        end
    end
    return saved
end

local function restoreWorldPortalRTs(saved)
    if not saved then return end
    for i = 1, #saved do
        local e = saved[i]
        -- prev may be nil (portal had never been drawn yet); SetTexture(nil)
        -- restores the original "skip" state so wp.renderportals' `texture`
        -- check leaves it alone on the next regular frame.
        if IsValid(e.portal) then
            e.portal:SetTexture(e.prev)
        end
    end
end

MCP:AddFunction({
    id = "screenshot",
    description = "Capture a JPEG screenshot. Without `origin`/`angles` returns a render of the local player's current viewport. Supplying `origin`+`angles` (and optional `fov`) re-renders the world from that arbitrary camera without moving the player. Output is downscaled to a sensible resolution (default 1280x720) regardless of the user's actual screen size.",
    schema = {
        type = "object",
        properties = {
            origin = {
                type = "array",
                description = "World camera position as [x, y, z]. When set, `angles` must also be set.",
                items = { type = "number" },
                minItems = 3,
                maxItems = 3,
            },
            angles = {
                type = "array",
                description = "Camera orientation as [pitch, yaw, roll] in degrees. Required when `origin` is set.",
                items = { type = "number" },
                minItems = 3,
                maxItems = 3,
            },
            fov = {
                type = "number",
                description = "Field of view in degrees (free-camera mode only; default 90). Player-view mode uses the player's current FOV.",
                minimum = 1,
                maximum = 179,
            },
            width = {
                type = "integer",
                description = "Output image width in pixels (default 1280). Decoupled from the user's screen — the world is re-rendered at this size.",
                minimum = 16,
                maximum = 4096,
            },
            height = {
                type = "integer",
                description = "Output image height in pixels (default 720).",
                minimum = 16,
                maximum = 4096,
            },
            quality = {
                type = "integer",
                description = "JPEG quality 1-100 (default 80). Lower = smaller payload, more compression artefacts.",
                minimum = 1,
                maximum = 100,
            },
        },
    },
    handler = function(args, ctx)
        args = args or {}
        local quality = math.Clamp(tonumber(args.quality) or 80, 1, 100)
        local outW = math.Clamp(math.floor(tonumber(args.width) or DEFAULT_W), 16, 4096)
        local outH = math.Clamp(math.floor(tonumber(args.height) or DEFAULT_H), 16, 4096)

        local customView = args.origin ~= nil or args.angles ~= nil
        local origin, angles, fov
        if customView then
            local ox, oy, oz = parseVec3(args.origin)
            local ap, ay, ar = parseVec3(args.angles)
            if not (ox and ap) then
                return {
                    ok = false,
                    error = "free-camera mode requires `origin` AND `angles` as 3-element number arrays",
                }
            end
            origin = Vector(ox, oy, oz)
            angles = Angle(ap, ay, ar)
            fov = math.Clamp(tonumber(args.fov) or DEFAULT_FOV, 1, 179)
        end

        local hookId = uniqueHookId()
        local fired = false
        local deadline = RealTime() + 2

        local function finish(response)
            if fired then return end
            fired = true
            hook.Remove("PostRender", hookId)
            hook.Remove("Think", hookId)
            ctx.respond(response)
        end

        hook.Add("PostRender", hookId, function()
            if fired then return end

            -- Resolve the camera. Player-view mode pulls the camera from
            -- the local player every frame so the snapshot reflects exactly
            -- what they're looking at right now.
            local viewOrigin, viewAngles, viewFov
            local playerEye = nil
            if customView then
                viewOrigin, viewAngles, viewFov = origin, angles, fov
            else
                local lp = LocalPlayer()
                if not IsValid(lp) then
                    finish({ ok = false, error = "no local player available for player-view capture" })
                    return
                end
                viewOrigin = lp:EyePos()
                viewAngles = lp:EyeAngles()
                viewFov = lp:GetFOV()
                if viewFov <= 0 then viewFov = DEFAULT_FOV end
                playerEye = { pos = viewOrigin, ang = viewAngles, fov = viewFov }
            end

            local primedPortals = primeWorldPortalRTs(outW, outH)
            local rvOk, rvErr = pcall(render.RenderView, {
                origin = viewOrigin,
                angles = viewAngles,
                fov = viewFov,
                -- Match the perspective math to the output viewport;
                -- without this the engine uses ScrW/ScrH for aspect, which
                -- stretches the world when the requested w/h has a
                -- different ratio than the user's monitor.
                aspectratio = outW / outH,
                x = 0, y = 0, w = outW, h = outH,
                -- world-portals' RenderView wrapper reads `width`/`height`
                -- (not `w`/`h`) from the view to size its inner portal
                -- render. Without these it falls back to ScrW/ScrH and
                -- fills the portal RTs at the wrong viewport size.
                width = outW, height = outH,
                drawhud = false,
                drawmonitors = false,
                -- Player-view: show the held weapon (gravgun etc.).
                -- Free-camera: hide it (camera isn't in the player's hands).
                drawviewmodel = not customView,
                -- Free-camera: show the player's body so a third-person
                -- shot includes them. Player-view: don't draw the player
                -- on top of their own first-person view.
                drawviewer = customView,
                dopostprocess = true,
                bloomtone = true,
            })
            restoreWorldPortalRTs(primedPortals)
            if not rvOk then
                finish({ ok = false, error = "render.RenderView failed: " .. tostring(rvErr) })
                return
            end

            local ok, data = pcall(render.Capture, {
                format = "jpeg",
                x = 0, y = 0,
                w = outW, h = outH,
                quality = quality,
            })
            if not ok then
                finish({ ok = false, error = "render.Capture threw: " .. tostring(data) })
                return
            end
            if type(data) ~= "string" or data == "" then
                finish({ ok = false, error = "render.Capture returned no data" })
                return
            end

            local encOk, encoded = pcall(util.Base64Encode, data, true)
            if not encOk or type(encoded) ~= "string" then
                finish({ ok = false, error = "Base64Encode failed: " .. tostring(encoded) })
                return
            end

            local desc
            if customView and origin and angles and fov then
                desc = string.format(
                    "Free-camera %dx%d JPEG @ q=%d (%d bytes). origin=[%g %g %g] angles=[%g %g %g] fov=%g",
                    outW, outH, quality, #data,
                    origin.x, origin.y, origin.z,
                    angles.p, angles.y, angles.r,
                    fov)
            elseif playerEye then
                desc = string.format(
                    "Player-view %dx%d JPEG @ q=%d (%d bytes). eye_origin=[%g %g %g] eye_angles=[%g %g %g] fov=%g",
                    outW, outH, quality, #data,
                    playerEye.pos.x, playerEye.pos.y, playerEye.pos.z,
                    playerEye.ang.p, playerEye.ang.y, playerEye.ang.r,
                    playerEye.fov)
            else
                desc = string.format("%dx%d JPEG @ q=%d (%d bytes).", outW, outH, quality, #data)
            end

            finish({
                ok = true,
                content = {
                    {
                        type = "image",
                        data = encoded,
                        mimeType = "image/jpeg",
                    },
                    {
                        type = "text",
                        text = desc,
                    },
                },
            })
        end)

        -- Think-based fallback: if PostRender never fires (window minimised,
        -- engine paused, loading screen) the caller still gets a structured
        -- error instead of timing out at the bridge layer. Think uses
        -- RealTime so it keeps ticking even when CurTime is paused.
        hook.Add("Think", hookId, function()
            if fired then return end
            if RealTime() < deadline then return end
            finish({
                ok = false,
                error = "screenshot timed out: PostRender did not fire within 2 s "
                    .. "(window may be minimised, occluded, or the engine is paused)",
            })
        end)

        return ctx.deferred
    end,
})
