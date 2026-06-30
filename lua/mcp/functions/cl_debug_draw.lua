-- debug_draw: the persistent member of the debug_* family. Install a managed client-side
-- render hook that runs caller-supplied draw Lua every frame -- world markers via
-- PostDrawTranslucentRenderables (3D, depth-tested) or HUD labels via HUDPaint (2D) -- and
-- keep it live across later tool calls and screenshots until debug_clear, an optional ttl, or
-- a replace removes it. Unlike debug_record (a blocking, windowed value sampler) this is
-- persistent and renders rather than returning a series. The tool owns the lifecycle: a unique
-- mcp_debug_ id (so debug_clear sweeps it), a per-frame pcall that auto-removes the draw on its
-- first error (so a broken draw can't spam 60x/second), and an optional ttl.
--
-- Caller Lua runs every frame (== lua_run power), so the whole tool rides the `unsafe` gate.
-- Client realm only -- render hooks are clientside. The handler defers up to CONFIRM_CAP for
-- the first render frame so it can report whether the draw rendered cleanly (verified), then
-- leaves the draw installed.

local SPACES = {
    world = "PostDrawTranslucentRenderables", -- 3D, depth-tested; render.* / cam.Start3D2D
    hud   = "HUDPaint",                       -- 2D screen space; draw.* / surface.*
}

local CONFIRM_CAP = 0.5  -- wait at most this long for the first render fire before reporting
local MAX_TTL = 3600     -- ttl hard cap (seconds)

-- Compile a caller snippet as a function body receiving the hook's args as `...`.
local function compileBody(src, name)
    local chunk = CompileString("return function(...)\n" .. src .. "\nend", name, false)
    if type(chunk) == "string" then return nil, chunk end
    return chunk()
end

MCP:AddFunction({
    id = "debug_draw",
    requires = { "unsafe" },
    description = "Install a persistent client-side render hook that runs your draw Lua every frame, for visual debugging you can then screenshot -- mark an entity, outline a volume, draw a path, label something on the HUD. A managed member of the debug_* family: the tool owns the lifecycle (unique mcp_debug_ hook id, per-frame error containment, optional ttl) and returns a `handle`; the draw STAYS LIVE across later tool calls and screenshots until you remove it. Unlike debug_record (a blocking, windowed value sampler), debug_draw is persistent and renders rather than returning a series. `space` picks the surface: \"world\" (default) draws in 3D via a PostDrawTranslucentRenderables hook (depth-tested -- use render.* and cam.Start3D2D for 3D text; for draw-through-walls call cam.IgnoreZ(true) in your draw); \"hud\" draws in 2D screen space via HUDPaint (use draw.*/surface.*). Note the current screenshot tool renders without the HUD pass, so hud-space draws show on the live screen but are not yet captured in screenshots, whereas world-space draws are -- prefer world space for anything you intend to screenshot. `draw` is a Lua function body (receives the hook's args as `...`) run EVERY frame, so read live state for a marker that tracks something, e.g. \"local e = Entity(78) if IsValid(e) then render.DrawWireframeBox(e:GetPos(), Angle(), e:OBBMins(), e:OBBMaxs(), Color(255,0,0), true) end\". Returns `handle` and `verified`: true once the draw rendered one frame without error; false with a note if the window is backgrounded and not rendering (the draw is still installed -- see render_focus). A compile error fails immediately; a runtime error on the first frame fails the call and removes the draw; a runtime error later auto-removes the draw (so it cannot spam errors 60x/second) and is surfaced in the next call's events. Remove a draw with debug_clear (clears every debug_* hook), an optional `ttl` (auto-remove after N seconds, like debugoverlay's time arg -- fire-and-forget, the call returns now), or `replace` (a prior handle to remove before installing this one, so iterating on a marker does not pile up).",
    schema = {
        type = "object",
        properties = {
            draw = {
                type = "string",
                description = "Lua function body run every frame to render the overlay; receives the hook's arguments as `...`. World space: render.* / cam.Start3D2D. HUD space: draw.* / surface.*. Read live state (Entity(n), LocalPlayer()) so a marker tracks its target.",
            },
            space = {
                type = "string",
                enum = { "world", "hud" },
                description = "Draw surface: \"world\" (default, 3D via PostDrawTranslucentRenderables) or \"hud\" (2D via HUDPaint).",
            },
            ttl = {
                type = "number",
                description = "Auto-remove the draw after this many seconds (max 3600), fire-and-forget. Omit to keep it until debug_clear or a replace removes it.",
            },
            replace = {
                type = "string",
                description = "A handle from a previous debug_draw to remove before installing this one -- use it to update a marker in place without piling up draws.",
            },
        },
        required = { "draw" },
    },
    handler = function(args, ctx)
        args = args or {}
        if type(args.draw) ~= "string" or args.draw == "" then
            return { ok = false, error = "`draw` must be a non-empty Lua snippet (the render code)" }
        end
        local space = args.space or "world"
        local hookPoint = SPACES[space]
        if not hookPoint then
            return { ok = false, error = "`space` must be \"world\" or \"hud\"" }
        end

        local drawFn, derr = compileBody(args.draw, "mcp_debug_draw")
        if not drawFn then return { ok = false, error = "`draw` compile error: " .. derr } end

        local ttl
        if args.ttl ~= nil then
            ttl = tonumber(args.ttl)
            if not ttl then return { ok = false, error = "`ttl` must be a number (seconds)" } end
            if ttl <= 0 then ttl = nil else ttl = math.min(ttl, MAX_TTL) end
        end

        MCP._debugDraws = MCP._debugDraws or {} -- handle -> record { hookPoint, space, ttl, error? }

        -- replace: remove a prior draw (by handle) before installing the new one.
        if args.replace ~= nil then
            if type(args.replace) ~= "string" then return { ok = false, error = "`replace` must be a draw handle string" } end
            local prev = MCP._debugDraws[args.replace]
            if prev then
                hook.Remove(prev.hookPoint, args.replace)
                MCP._debugDraws[args.replace] = nil
            end
        end

        MCP._debugSeq = (MCP._debugSeq or 0) + 1
        local handle = "mcp_debug_" .. MCP._debugSeq
        local rec = { hookPoint = hookPoint, space = space, ttl = ttl }

        local firstFire, fireError, removed

        local function removeDraw()
            if removed then return end
            removed = true
            hook.Remove(hookPoint, handle)
            if MCP._debugDraws[handle] == rec then MCP._debugDraws[handle] = nil end
        end

        hook.Add(hookPoint, handle, function(...)
            if removed then return end
            local ok, err = pcall(drawFn, ...)
            if not ok then
                rec.error = tostring(err)
                if firstFire then
                    -- Late error (past the confirmed first frame): the caller already has
                    -- their response, so surface it via the console events array.
                    MsgN("[mcp] debug_draw " .. handle .. " auto-removed after a draw error: " .. rec.error)
                else
                    firstFire, fireError = true, rec.error
                end
                removeDraw()
                return
            end
            firstFire = true
        end)

        MCP._debugDraws[handle] = rec

        -- Defer for the first render fire so we can report whether the draw rendered cleanly.
        -- A backgrounded window may never render within the cap (verified=false, draw left in).
        MCP:RunFor({
            seconds = CONFIRM_CAP,
            stop = function() return firstFire end,
        }, function()
            if fireError then
                ctx.respond({
                    ok = false,
                    realm = MCP.util.RealmName(),
                    handle = handle,
                    space = space,
                    hook = hookPoint,
                    verified = false,
                    removed = true,
                    error = "`draw` error on first frame: " .. fireError,
                })
                return
            end

            local verified = firstFire == true
            local result = {
                ok = true,
                realm = MCP.util.RealmName(),
                handle = handle,
                space = space,
                hook = hookPoint,
                verified = verified,
            }
            if not verified then
                result.note = "render hook did not fire within " .. CONFIRM_CAP .. "s (window may be backgrounded/occluded); the draw is installed and will render once the view is visible -- see render_focus"
            end
            if ttl then result.ttl = ttl end

            ctx.respond(result)

            -- Fire-and-forget ttl: revert after the response, removing only if this draw still
            -- owns the handle (handles are unique + monotonic, so no ABA).
            if ttl then
                MCP:RunFor({ seconds = ttl }, function()
                    if MCP._debugDraws[handle] == rec then removeDraw() end
                end)
            end
        end)

        return ctx.deferred
    end,
})
