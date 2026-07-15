-- Capture a JPEG screenshot and return it as MCP image content so the
-- assistant can see the in-game state directly.
--
-- We capture the GENUINE back buffer - the finished frame the engine already
-- drew for the player (world, HUD, portals, RenderScene output all correct) -
-- never `render.RenderView`. Re-rendering the world (the old approach) skipped
-- RenderScene hooks and drew world-portals as false black rectangles, so the
-- capture diverged from what the player actually sees. Instead we copy the real
-- back buffer into a texture, GPU-downscale it into a small render target, and
-- `render.Capture` the RT.
--
-- Downscaling can't happen by rendering the whole game smaller for one frame
-- (that IS RenderView) - the engine renders at native res, so we downscale the
-- finished frame: CopyRenderTargetToTexture into an exact screen-sized RT, blit
-- it into an outW x outH RT (GPU minify), capture. `max_size` caps the longest
-- edge; aspect always follows the real screen and we never upscale.
--
-- HUD on -> capture in `PostRender` (fully composited: world + HUD + VGUI).
-- HUD off -> capture in `PreDrawHUD` (after the full 3D render, before any 2D
-- pass), which yields the world with zero HUD - robust even against addons that
-- draw the HUD unconditionally, which neither cl_drawhud nor HUDShouldDraw can
-- suppress.
--
-- Known limit: a multi-pass main-buffer post-process (pp_stereoscopy draws each
-- eye as its own PreDrawHUD pass) has its full composite only at PostRender, where
-- the HUD also is - so a HUD-off/freecam shot of one grabs a single pass (one eye).
-- Not worked around: no HUD-free capture point is also fully composited.
--
-- Two camera modes:
--   * Player-view (no `origin`/`angles`): capture the real screen verbatim.
--     HUD shown by default; zero on-screen disturbance.
--   * Free-camera (`origin`+`angles`): override the engine's own view for ONE
--     frame via `CalcView` (so portals/reflections stay correct, unlike
--     RenderView), body drawn, viewmodel and HUD hidden. The user's monitor
--     shows that camera for a single frame. CalcView is a shared
--     first-non-nil-wins hook, so we read EyePos()/EyeAngles() (the true render
--     view) and warn if another addon's CalcView superseded ours. Things the
--     camera sees that are outside the PLAYER's PVS are dormant and would render
--     missing (world-portal surfaces), so the server extends the host's PVS to
--     the camera origin (sh_screenshot_pvs.lua) and we hold the shot until the
--     entities it lists have actually un-dormanted - a done-condition robust to a
--     frozen or high-ping host, not a fixed settle.
--
-- Optionally armed: a `trigger` Lua expression is polled each render frame and the
-- shot is grabbed on the first frame it goes truthy (to catch a transient), capped
-- by `trigger_seconds` (then a timeout error). It's evaluated in the render hooks,
-- so it sees the same frame that gets captured.
--
-- `render.Capture` needs an active render context, so the handler defers via
-- `ctx.deferred` and resolves from the capture hook. A `Think`-based deadline is
-- the fallback when no frame renders (minimised, paused).

local DEFAULT_MAX_SIZE = 1280
local DEFAULT_FOV = 90

-- Safety cap on an armed `trigger` wait; keep <= the declared per-tool timeout.
local MAX_TRIGGER = 30

-- Every saved screenshot lives under this one data/ subfolder (then a
-- per-session subfolder), so the startup wipe below has a single, well-defined
-- place to clear.
local SCREENSHOT_DIR = "mcp/screenshots"

-- Per-session monotonic counter for screenshot filenames. Kept on the MCP
-- table so it survives autorefresh; a fresh game start (new Lua state) resets
-- it, which lines up with the startup folder wipe.
MCP._screenshotSeq = MCP._screenshotSeq or {}

-- Lazily-built GPU resources for the downscale blit. Not created at file load:
-- CreateMaterial/GetRenderTarget are game globals that are nil under the
-- headless MoonSharp tool-list generator, which loads this file to read the
-- schema. Built on first handler call and cached.
---@type table<string, ITexture>
local srcCache = {}   -- screen-sized copies of the back buffer, keyed "WxH"
---@type table<string, ITexture>
local dstCache = {}   -- downscale destinations, keyed "WxH"
---@type table<string, IMaterial>
local matCache = {}   -- blit materials, keyed by their source texture name

---@param cache table<string, ITexture>
---@param prefix string
---@param w number
---@param h number
---@return ITexture
local function ensureRT(cache, prefix, w, h)
    local key = w .. "x" .. h
    local rt = cache[key]
    if rt then return rt end
    rt = GetRenderTarget(prefix .. key, w, h)
    cache[key] = rt
    return rt
end

-- The source RT's content is refreshed each capture via CopyRenderTargetToTexture,
-- so one material per source texture is enough (its $basetexture is fixed).
---@param srcRT ITexture
---@return IMaterial
local function ensureBlitMat(srcRT)
    local name = srcRT:GetName()
    local mat = matCache[name]
    if mat then return mat end
    mat = CreateMaterial("mcp_screenshot_blit_" .. name, "UnlitGeneric", {
        ["$basetexture"] = name,
        ["$translucent"] = "0",
        ["$ignorez"] = "1",
    })
    matCache[name] = mat
    return mat
end

local function uniqueHookId()
    return "MCP_Screenshot_" .. tostring(SysTime()) .. "_" .. tostring(math.random(1, 1e9))
end

---@param t table
local function parseVec3(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
    if not (x and y and z) then return nil end
    return x, y, z
end

-- Clear screenshots left by previous runs so the folder never grows unbounded.
-- Fires once on client startup; re-registering on autorefresh is harmless since
-- Initialize only runs at genuine startup, never on reload.
---@param dir string?
local function wipeScreenshotDir(dir)
    dir = dir or SCREENSHOT_DIR
    local files, dirs = file.Find(dir .. "/*", "DATA")
    for _, f in ipairs(files or {}) do
        file.Delete(dir .. "/" .. f)
    end
    for _, d in ipairs(dirs or {}) do
        wipeScreenshotDir(dir .. "/" .. d)
        file.Delete(dir .. "/" .. d)
    end
end
hook.Add("Initialize", "MCP_ScreenshotDirWipe", function() wipeScreenshotDir() end)

MCP:AddFunction({
    id = "screenshot",
    timeout = MAX_TRIGGER + 3, -- room for an armed `trigger` wait; a plain shot returns at once
    description = "Capture a JPEG of what the player actually sees on screen - the genuine rendered frame (HUD, portals, post-processing all as-live), not a re-render, so the image matches the game exactly. Without `origin`/`angles` it captures the local player's real viewport (HUD included). Supplying `origin`+`angles` (and optional `fov`) overrides the camera for a single frame via CalcView to shoot from an arbitrary world position without moving the player (HUD hidden, player body shown); it briefly extends the player's PVS to the camera so out-of-view world-portal surfaces and other entities still render. Optionally arm the shot with `trigger`: a Lua expression polled each render frame; the capture is taken on the first frame it returns truthy (capped by `trigger_seconds`, default 30, after which a timeout error is returned instead of a frame) - use it to catch a transient on-screen moment. Output is downscaled so the longest edge is at most `max_size` (default 1280) while preserving the real screen aspect ratio (never upscaled). Every shot is ALWAYS saved under data/mcp/screenshots/<session>/ with an auto-generated name (seq_time_mode, e.g. 0003_153122_player.jpg) and that path is returned as text; the folder is wiped on each game startup. By default only the path is returned (so a human can watch the folder live, or an out-of-band analyzer like Gemini can read it without the bytes entering the agent's context); pass `inline=true` to also receive the raw image.",
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
            max_size = {
                type = "integer",
                description = "Cap on the longest output edge in pixels (default 1280). The real screen aspect ratio is preserved and the image is never upscaled, so on a 1920x1080 screen max_size=1280 yields 1280x720, on 2560x1440 also 1280x720.",
                minimum = 16,
                maximum = 4096,
            },
            quality = {
                type = "integer",
                description = "JPEG quality 1-100 (default 80). Lower = smaller payload, more compression artefacts.",
                minimum = 1,
                maximum = 100,
            },
            hud = {
                type = "boolean",
                description = "Whether to draw the HUD. Default depends on mode: player-view shows it (verbatim screen), free-camera hides it (it would float over the detached camera).",
            },
            inline = {
                type = "boolean",
                description = "When true, also return the raw JPEG inline so the calling agent can see the image directly (costs context tokens). Default false: only the saved file path is returned - open it live, or hand it to an out-of-band analyzer (e.g. Gemini) without the bytes entering the agent's context.",
            },
            trigger = {
                type = "string",
                description = "A Lua expression polled each render frame; the screenshot is captured on the first frame it returns truthy - use it to catch a transient on-screen moment. E.g. \"IsValid(ents.GetByIndex(7)) and ents.GetByIndex(7):GetVelocity():Length() > 300\". If it never becomes true within `trigger_seconds` a timeout error is returned instead of a frame; a trigger that errors ends the call with that error.",
            },
            trigger_seconds = {
                type = "number",
                minimum = 0.05,
                maximum = MAX_TRIGGER,
                description = "Cap in seconds on the `trigger` wait (default 30, max 30). On expiry a timeout error is returned rather than a frame. Only applies with `trigger`.",
            },
        },
    },
    arg_requires = { trigger = { "unsafe" } },
    asyncable = true,
    handler = function(args, ctx)
        args = args or {}
        local quality = math.Clamp(math.floor(tonumber(args.quality) or 80), 1, 100)
        local maxSize = math.Clamp(math.floor(tonumber(args.max_size) or DEFAULT_MAX_SIZE), 16, 4096)

        -- Output tracks the real screen aspect; downscale only, never upscale.
        local sw, sh = ScrW(), ScrH()
        local scale = math.min(1, maxSize / math.max(sw, sh))
        local outW = math.max(1, math.Round(sw * scale))
        local outH = math.max(1, math.Round(sh * scale))

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

        -- Per-mode HUD default: player-view mirrors the real screen (HUD on),
        -- free-camera hides it since it is anchored to the first-person view.
        local hud
        if args.hud ~= nil then
            hud = args.hud == true
        else
            hud = not customView
        end

        local inline = args.inline == true

        -- Armed trigger: compile the predicate up front so a typo fails fast,
        -- before we defer. Gated behind `unsafe` (arg_requires) since it runs
        -- caller Lua each frame.
        local hasTrigger = args.trigger ~= nil
        local triggerFn
        if hasTrigger then
            if type(args.trigger) ~= "string" then
                return { ok = false, error = "`trigger` must be a Lua expression string" }
            end
            local c = CompileString("return (" .. args.trigger .. ")", "mcp_screenshot_trigger", false)
            if type(c) == "string" then
                return { ok = false, error = "`trigger` compile error: " .. c }
            end
            triggerFn = c
        elseif args.trigger_seconds ~= nil then
            return { ok = false, error = "`trigger_seconds` only applies with `trigger`" }
        end
        local triggerCap = math.Clamp(tonumber(args.trigger_seconds) or MAX_TRIGGER, 0.05, MAX_TRIGGER)

        -- Each shot is saved under a per-session folder so concurrent MCP hosts
        -- never clobber each other; the seq_time_mode filename is built at write
        -- time. ctx.session is already filename-safe (IsSafeId-gated) but
        -- sanitize defensively in case a non-bridge caller supplied it.
        local sess = string.gsub(tostring(ctx and ctx.session or ""), "[^%w%.%-]", "")
        if sess == "" then sess = "local" end
        local sessionDir = SCREENSHOT_DIR .. "/" .. sess
        local mode = customView and "freecam" or "player"

        local hookId = uniqueHookId()
        local fired = false
        local appliedFrame       -- frame our CalcView drove the render (freecam)
        local calcViewRan = false
        local sawFrame = false    -- a PreDrawHUD fired at all (frames are rendering)
        local sawMainView = false -- a main-framebuffer PreDrawHUD fired (not just sub-render RTs)
        ---@type Vector?
        local renderPos          -- true render view, recorded during the 3D pass
        ---@type Angle?
        local renderAng

        -- Free camera: extend the host's PVS to the camera origin so anything the
        -- camera sees that's outside the player's PVS (world-portal surfaces etc.)
        -- networks + un-dormants before we capture, then hold the shot until the
        -- entities the server lists have actually arrived - a done-condition that
        -- holds for a frozen or high-ping host, not a fixed settle. See
        -- libraries/sh_screenshot_pvs.lua.
        local sentPVS = false
        ---@type MCP.ScreenshotPVSWait?
        local pvsWait
        local pvsStalled = false   -- gave up waiting; capture with a warning
        local pvsPending = 0       -- entities still not live at capture (stall only)
        local pvsSettledMs         -- request -> ready, reported to the caller
        local pvsBeganAt = RealTime()
        if customView and origin then
            pvsWait = MCP.screenshotPVS.Begin(origin)
            sentPVS = true
        end
        -- Generous stall-guard, well under the tool's timeout; pvsReady() is the
        -- real gate. frameDeadline is armed only once ready, to catch a frame that
        -- never renders (minimised / paused).
        local pvsDeadline = RealTime() + 10
        local frameDeadline

        -- Armed-trigger wait state. The predicate is polled in the render hooks
        -- (so it sees the frame that gets grabbed) and latched on first truthy;
        -- triggerDeadline caps the wait.
        local triggered = false
        local triggerChecked = false   -- predicate polled at least once
        local triggerImmediate = false -- true on its first check: may have fired before we watched
        local triggerFiredMs           -- arm -> fired, reported to the caller
        local triggerBeganAt = RealTime()
        local triggerDeadline          -- armed once PVS is good (the trigger's cap window)

        -- True once PVS propagation is confirmed complete (every listed entity is
        -- live) or we gave up (pvsStalled). Records the settle time on first ready.
        local function pvsReady()
            if not sentPVS or pvsStalled then return true end
            local pending = MCP.screenshotPVS.Pending(pvsWait)
            if pending == nil or #pending > 0 then return false end
            pvsSettledMs = pvsSettledMs or math.Round((RealTime() - pvsBeganAt) * 1000)
            return true
        end

        -- Remove every hook and release the PVS extension. Split from finish() so
        -- job_cancel (via ctx.onCancel) can tear the shot down without responding.
        local function teardown()
            fired = true
            hook.Remove("PostRender", hookId)
            hook.Remove("Think", hookId)
            hook.Remove("PreDrawHUD", hookId)
            hook.Remove("CalcView", hookId)
            hook.Remove("PreDrawViewModel", hookId)
            if sentPVS then MCP.screenshotPVS.Finish(pvsWait) end
        end
        ---@param response table
        local function finish(response)
            if fired then return end
            teardown()
            ctx.respond(response)
        end
        ctx.onCancel(teardown)

        -- Armed-trigger gate: hold the shot until the caller's predicate first
        -- goes truthy, latched so a one-frame-true predicate isn't missed by a
        -- re-check later in the same frame. A predicate throw ends the call.
        local function triggerReady()
            if not hasTrigger or triggered then return true end
            local ok, val = pcall(triggerFn)
            if not ok then
                finish({ ok = false, error = "`trigger` error: " .. tostring(val) })
                return false
            end
            local firstCheck = not triggerChecked
            triggerChecked = true
            if val then
                triggered = true
                triggerImmediate = firstCheck
                triggerFiredMs = math.Round((RealTime() - triggerBeganAt) * 1000)
            end
            return triggered
        end

        if customView then
            hook.Add("CalcView", hookId, function()
                if fired or not pvsReady() or not triggerReady() then return end
                calcViewRan = true
                appliedFrame = FrameNumber()
                return { origin = origin, angles = angles, fov = fov, drawviewer = true }
            end)
            hook.Add("PreDrawViewModel", hookId, function()
                if fired or not pvsReady() or not triggered then return end
                return true
            end)
        end

        -- RT-blit capture from whatever is currently on the back buffer, then
        -- save and respond. Called from PreDrawHUD (HUD off) or PostRender (HUD on).
        ---@param eyePos Vector
        ---@param eyeAng Angle
        local function captureFrom(eyePos, eyeAng)
            if fired then return end

            -- Copy the current back buffer into an exact screen-sized texture,
            -- then blit it downscaled into the output RT. No scene re-render, so
            -- RenderScene output and portals stay correct; render.DrawScreenQuad
            -- fills the whole active RT regardless of the 2D coord space, so the
            -- downscale is a clean GPU minify.
            local srcRT = ensureRT(srcCache, "mcp_screenshot_src_", sw, sh)
            render.CopyRenderTargetToTexture(srcRT)
            local dstRT = ensureRT(dstCache, "mcp_screenshot_dst_", outW, outH)
            local mat = ensureBlitMat(srcRT)

            render.PushRenderTarget(dstRT)
            render.Clear(0, 0, 0, 255)
            cam.Start2D()
            render.SetMaterial(mat)
            render.DrawScreenQuad()
            cam.End2D()
            local ok, data = pcall(render.Capture, {
                format = "jpeg",
                x = 0, y = 0,
                w = outW, h = outH,
                quality = quality,
            })
            render.PopRenderTarget()

            if not ok then
                finish({ ok = false, error = "render.Capture threw: " .. tostring(data) })
                return
            end
            if type(data) ~= "string" or data == "" then
                finish({
                    ok = false,
                    error = "render.Capture returned no data (is the game paused or the escape menu open?)",
                })
                return
            end

            -- Player-view: report the eye. Free-camera: verify the engine used
            -- our requested view and warn if a shared CalcView hook overrode it.
            local desc
            if customView and origin and angles and fov then
                local posOff = eyePos:Distance(origin)
                local angOff = math.max(
                    math.abs(math.AngleDifference(eyeAng.p, angles.p)),
                    math.abs(math.AngleDifference(eyeAng.y, angles.y)),
                    math.abs(math.AngleDifference(eyeAng.r, angles.r))
                )
                desc = string.format(
                    "Free-camera %dx%d JPEG @ q=%d (%d bytes) from a %dx%d screen. origin=[%g %g %g] angles=[%g %g %g] fov=%g%s",
                    outW, outH, quality, #data, sw, sh,
                    origin.x, origin.y, origin.z,
                    angles.p, angles.y, angles.r,
                    fov,
                    pvsSettledMs and string.format(" PVS settled in %d ms.", pvsSettledMs) or "")
                if posOff > 1 or angOff > 1 then
                    desc = string.format(
                        "WARNING: rendered camera was off by %.1f units / %.1f deg from the request "
                            .. "(another CalcView hook likely took precedence). Actually rendered "
                            .. "origin=[%g %g %g] angles=[%g %g %g]. ",
                        posOff, angOff,
                        eyePos.x, eyePos.y, eyePos.z,
                        eyeAng.p, eyeAng.y, eyeAng.r) .. desc
                end
                if pvsStalled then
                    local warn
                    if pvsPending < 0 then
                        warn = "WARNING: the PVS target list never arrived from the server, so PVS "
                            .. "readiness could not be verified; out-of-view entities (world-portal "
                            .. "surfaces etc.) may render missing. "
                    elseif pvsPending > 0 then
                        warn = string.format(
                            "WARNING: PVS not fully settled - %d in-view entit%s still dormant when the "
                                .. "PVS wait timed out; they may render missing. ",
                            pvsPending, pvsPending == 1 and "y was" or "ies were")
                    end
                    if warn then desc = warn .. desc end
                end
            else
                desc = string.format(
                    "Player-view %dx%d JPEG @ q=%d (%d bytes) from a %dx%d screen, HUD %s. eye_origin=[%g %g %g] eye_angles=[%g %g %g]",
                    outW, outH, quality, #data, sw, sh,
                    hud and "on" or "off",
                    eyePos.x, eyePos.y, eyePos.z,
                    eyeAng.p, eyeAng.y, eyeAng.r)
            end

            if triggerFiredMs then
                if triggerImmediate then
                    desc = desc .. string.format(
                        " Trigger was already true on the first watched frame (%d ms in) - the shot may be"
                        .. " past the moment it first became true, not its leading edge (the condition may"
                        .. " already have held when watching began, e.g. a steady state rather than a transient).",
                        triggerFiredMs)
                else
                    desc = desc .. string.format(" Trigger fired after %d ms.", triggerFiredMs)
                end
            end

            -- Always persist the shot so a human can watch the folder live;
            -- embed the bytes inline only when the caller opted in. Seq is bumped
            -- here, post-capture, so a failed render doesn't leave a gap.
            local seq = (MCP._screenshotSeq[sess] or 0) + 1
            MCP._screenshotSeq[sess] = seq
            local savePath = string.format("%s/%04d_%s_%s.jpg", sessionDir, seq, os.date("%H%M%S"), mode)

            file.CreateDir(sessionDir)
            local wOk, wErr = pcall(file.Write, savePath, data)
            if not wOk then
                finish({ ok = false, error = "file.Write failed for data/" .. savePath .. ": " .. tostring(wErr) })
                return
            end
            if not file.Exists(savePath, "DATA") then
                finish({ ok = false, error = "wrote data/" .. savePath .. " but it is not present afterward" })
                return
            end

            -- `path` is data-relative; the .NET host resolves it to an absolute
            -- disk path (it knows --data-path; GMod Lua can't) and appends that.
            local content = { { type = "text", text = desc } }
            if inline then
                local encOk, encoded = pcall(util.Base64Encode, data, true)
                if not encOk or type(encoded) ~= "string" then
                    finish({ ok = false, error = "Base64Encode failed: " .. tostring(encoded) })
                    return
                end
                table.insert(content, 1, { type = "image", data = encoded, mimeType = "image/jpeg" })
            end
            finish({ ok = true, content = content, path = savePath })
        end

        -- The capture point depends on the HUD choice. PreDrawHUD fires after the
        -- full 3D render but before any 2D/HUD pass, so grabbing the back buffer
        -- there yields the world with zero HUD - robust even against addons that
        -- draw the HUD unconditionally (neither cl_drawhud nor HUDShouldDraw can
        -- suppress those). With the HUD wanted, PostRender grabs the fully
        -- composited frame instead. EyePos/EyeAngles are only reliable in this 3D
        -- pass (a later read zeroes the angles), so record them here for the
        -- PostRender path too. The freecam gate keeps us on the frame our CalcView
        -- actually drove; if another addon keeps winning that chain, appliedFrame
        -- never lands here and the Think deadline reports it.
        hook.Add("PreDrawHUD", hookId, function()
            if fired then return end
            sawFrame = true
            -- PreDrawHUD also fires inside other addons' sub-renders (world-portals
            -- renders each portal's inner view via render.RenderView into its own RT,
            -- firing this hook for that pass). Those render to a pushed RT; the real
            -- frame renders to the main framebuffer (GetRenderTarget nil). Skip the
            -- sub-renders so we read/capture only the actual player/freecam view.
            if render.GetRenderTarget() then return end
            sawMainView = true
            renderPos, renderAng = EyePos(), EyeAngles()
            if not pvsReady() then return end
            if not triggerReady() then return end
            if hud then return end
            if customView and appliedFrame ~= FrameNumber() then return end
            captureFrom(renderPos, renderAng)
        end)

        if hud then
            hook.Add("PostRender", hookId, function()
                if fired then return end
                if not pvsReady() then return end
                if not triggerReady() then return end
                if customView and appliedFrame ~= FrameNumber() then return end
                captureFrom(renderPos or EyePos(), renderAng or EyeAngles())
            end)
        end

        -- Think-based fallback: if no frame renders (window minimised, engine
        -- paused, loading screen) the caller still gets a structured error instead
        -- of timing out at the bridge layer. Think uses RealTime so it keeps
        -- ticking even when CurTime is paused.
        hook.Add("Think", hookId, function()
            if fired then return end
            local now = RealTime()

            -- Phase 1: hold for PVS to propagate (freecam only). The trigger is not
            -- watched until PVS is good, so it only ever fires on a fully-populated
            -- frame. If PVS overruns its deadline, stop waiting and proceed with a
            -- warning rather than hang - an honest safety net, not the mechanism.
            if not pvsReady() then
                if now < pvsDeadline then return end
                local pending = MCP.screenshotPVS.Pending(pvsWait)
                pvsPending = pending and #pending or -1 -- -1: list never arrived
                pvsStalled = true
            end

            -- Phase 2: PVS is ready (or we gave up). Now watch for the armed
            -- trigger, giving it its full cap from the moment the gate opened (not
            -- from the call start), so a slow PVS settle doesn't eat the window. If
            -- it never fires, error rather than grab an arbitrary frame (unlike the
            -- PVS stall, which warns and shoots - a never-true trigger has no
            -- meaningful frame to capture). A paused/minimised game trips this too,
            -- since the predicate is polled only in the render hooks.
            if hasTrigger and not triggered then
                triggerDeadline = triggerDeadline or (now + triggerCap)
                if now < triggerDeadline then return end
                finish({
                    ok = false,
                    reason = "timeout",
                    error = string.format("screenshot `trigger` never became true within %g s", triggerCap),
                })
                return
            end

            -- Phase 3: PVS ready and trigger fired (or neither is armed). Give a
            -- frame a moment to be grabbed; if none is, report why instead of
            -- timing out at the bridge layer.
            frameDeadline = frameDeadline or (now + 2)
            if now < frameDeadline then return end

            if customView and not calcViewRan then
                finish({
                    ok = false,
                    error = "screenshot timed out: the requested free camera was never applied - "
                        .. "another CalcView hook took precedence every frame for 2 s",
                })
                return
            end
            if sawFrame and not sawMainView then
                finish({
                    ok = false,
                    error = "screenshot timed out: every render pass this frame went to an "
                        .. "off-screen render target (an addon may be rendering the whole view "
                        .. "to an RT), so the main framebuffer view could not be captured",
                })
                return
            end
            finish({
                ok = false,
                error = "screenshot timed out: no frame rendered within 2 s "
                    .. "(window may be minimised, occluded, or the engine is paused)",
            })
        end)

        return ctx.deferred
    end,
})
