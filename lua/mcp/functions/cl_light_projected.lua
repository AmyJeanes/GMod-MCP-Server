-- light_projected: manage clientside ProjectedTexture test-lights (create / update / remove).
-- The projected-light sibling of debug_draw: create a spotlight, get a handle, keep it live
-- across tool calls/screenshots, then update or remove it. ProjectedTexture is a client render
-- object (non-networked); the tool runs no caller Lua, only structured knobs.

local MAX_TTL = 300
local DEFAULT_TEXTURE = "effects/flashlight001"

-- Persist across mcp_reload so handles survive an in-memory reload (like MCP._debugDraws).
MCP._lights = MCP._lights or {}

local function clamp255(n) return math.Clamp(math.floor(tonumber(n) or 0), 0, 255) end

-- [r,g,b] or [r,g,b,a] (0-255, clamped) -> Color. Returns nil + error string on bad shape.
local function parseColor(c)
    if type(c) ~= "table" then return nil, "`color` must be an [r,g,b] (or [r,g,b,a]) array" end
    if c[1] == nil or c[2] == nil or c[3] == nil then return nil, "`color` needs at least r,g,b" end
    return Color(clamp255(c[1]), clamp255(c[2]), clamp255(c[3]), c[4] ~= nil and clamp255(c[4]) or 255)
end

local function toVec(t) return Vector(tonumber(t[1]) or 0, tonumber(t[2]) or 0, tonumber(t[3]) or 0) end

MCP:AddFunction({
    id = "light_projected",
    description = "Create, update, or remove a clientside ProjectedTexture -- a spotlight test-light rig, the projected-light sibling of debug_draw. The tool owns the lifecycle: a create returns a `handle`, the light stays live across tool calls and screenshots until you remove it (or its `ttl` elapses), and you can update or replace it by handle. Runs no caller Lua -- just structured knobs. To CREATE: give `pos` [x,y,z] plus a direction (`angles` [p,y,r] OR `look_at` [x,y,z] to point at a spot); optional `color` [r,g,b(,a)] 0-255, `brightness` (default 8), `fov` cone degrees (default 90), `distance` far reach (SetFarZ, default 1024), `near` (SetNearZ), `texture` light cookie (default \"effects/flashlight001\"), `shadows` (default false -- shadow-casting projected textures share a tight engine budget), `nocull` (SetNoCull -- keep the light rendering from any view angle instead of being frustum-culled; the go-to lever when a shadow light vanishes when viewed off-axis; default false), `target` (entindex to SetTargetEntity), `ttl` seconds to auto-remove, `replace` a prior handle (remove-then-create so you can iterate without piling up). To UPDATE: pass `handle` + any subset of the same knobs. To REMOVE: `remove` <handle>, or `remove_all` true. Returns the handle + applied state + `valid` (the object was created -- note whether it actually RENDERS depends on the engine's projected-texture budget, r_projectedtexture_count, especially with shadows). Not swept by debug_clear (that is hook-only) -- use remove/remove_all here.",
    schema = {
        type = "object",
        properties = {
            pos = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "Light position [x,y,z]. Required to create; optional to move on update." },
            angles = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "Aim direction [pitch,yaw,roll]. Provide this OR look_at when creating." },
            look_at = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "Point [x,y,z] to aim the light at (direction computed from pos). Alternative to angles." },
            color = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 4, description = "Light colour [r,g,b] or [r,g,b,a], 0-255 (clamped). Default white." },
            brightness = { type = "number", description = "Light intensity (default 8 on create). Higher = brighter." },
            fov = { type = "number", description = "Cone angle in degrees, 1-179 (sets both horizontal+vertical FOV). Default 90." },
            distance = { type = "number", description = "Far reach in units (SetFarZ). Default 1024." },
            near = { type = "number", description = "Near plane distance (SetNearZ). Optional." },
            texture = { type = "string", description = "Projected light-cookie material path. Default \"effects/flashlight001\"." },
            shadows = { type = "boolean", description = "Cast shadows (default false -- shadow projected textures share a tight engine budget)." },
            nocull = { type = "boolean", description = "Disable the angle-based frustum cull (SetNoCull) so the light keeps rendering from any view angle -- the fix when a shadow-casting light vanishes when looked at off-axis. Default false (engine default)." },
            target = { type = "integer", description = "Entindex to SetTargetEntity (the light follows/targets it). Optional." },
            ttl = { type = "number", description = "Auto-remove the light after this many seconds (max 300). Fire-and-forget." },
            handle = { type = "string", description = "Update an existing light by its handle (from a prior create)." },
            replace = { type = "string", description = "On create, remove this prior handle first (iterate a light without piling up)." },
            remove = { type = "string", description = "Remove the light with this handle." },
            remove_all = { type = "boolean", description = "Remove every light this tool created." },
        },
        required = {},
    },
    handler = function(args)
        args = args or {}

        if args.remove_all then
            local n = 0
            for h, pt in pairs(MCP._lights) do
                if IsValid(pt) then pt:Remove() end
                MCP._lights[h] = nil
                n = n + 1
            end
            return { ok = true, realm = MCP.util.RealmName(), action = "remove_all", removed = n }
        end

        if args.remove ~= nil then
            if type(args.remove) ~= "string" then return { ok = false, error = "`remove` must be a light handle string" } end
            local pt = MCP._lights[args.remove]
            if pt == nil then return { ok = true, realm = MCP.util.RealmName(), action = "remove", handle = args.remove, removed = false, note = "no such handle (already gone)" } end
            if IsValid(pt) then pt:Remove() end
            MCP._lights[args.remove] = nil
            return { ok = true, realm = MCP.util.RealmName(), action = "remove", handle = args.remove, removed = true }
        end

        -- Create vs update.
        local pt, handle, action, nocullState
        if args.handle ~= nil then
            if type(args.handle) ~= "string" then return { ok = false, error = "`handle` must be a string" } end
            pt = MCP._lights[args.handle]
            if not IsValid(pt) then return { ok = false, error = "no live light with handle " .. args.handle .. " (create one first, or omit handle)" } end
            handle, action = args.handle, "update"
        else
            if type(args.pos) ~= "table" then return { ok = false, error = "`pos` [x,y,z] is required to create a light" } end
            if args.angles == nil and args.look_at == nil then
                return { ok = false, error = "creating a light needs a direction: give `angles` [p,y,r] or `look_at` [x,y,z]" }
            end
            if args.replace ~= nil then
                local old = MCP._lights[args.replace]
                if old ~= nil then
                    if IsValid(old) then old:Remove() end
                    MCP._lights[args.replace] = nil
                end
            end
            pt = ProjectedTexture()
            MCP._debugSeq = (MCP._debugSeq or 0) + 1
            handle = "mcp_light_" .. MCP._debugSeq
            action = "create"
            -- Create-time defaults so a bare create is a visible spotlight.
            pt:SetTexture(DEFAULT_TEXTURE)
            pt:SetBrightness(8)
            pt:SetFarZ(1024)
            pt:SetFOV(90)
            pt:SetColor(color_white)
            pt:SetEnableShadows(false) -- a fresh PT defaults shadows ON; force off (cheaper, matches the doc)
            pt:SetNoCull(false) -- engine default; set explicitly so a bare create's reported nocull is honest
            nocullState = false
            MCP._lights[handle] = pt
        end

        -- Apply the provided knobs (any subset).
        if args.pos ~= nil then pt:SetPos(toVec(args.pos)) end

        if args.look_at ~= nil then
            local origin = args.pos ~= nil and toVec(args.pos) or pt:GetPos()
            pt:SetAngles((toVec(args.look_at) - origin):GetNormalized():Angle())
        elseif args.angles ~= nil then
            pt:SetAngles(Angle(tonumber(args.angles[1]) or 0, tonumber(args.angles[2]) or 0, tonumber(args.angles[3]) or 0))
        end

        if args.color ~= nil then
            local col, cerr = parseColor(args.color)
            if not col then return { ok = false, error = cerr } end
            pt:SetColor(col)
        end
        if args.brightness ~= nil then pt:SetBrightness(math.max(tonumber(args.brightness) or 0, 0)) end
        if args.fov ~= nil then pt:SetFOV(math.Clamp(tonumber(args.fov) or 90, 1, 179)) end
        if args.distance ~= nil then pt:SetFarZ(math.max(tonumber(args.distance) or 0, 0)) end
        if args.near ~= nil then pt:SetNearZ(math.max(tonumber(args.near) or 0, 0)) end
        if args.texture ~= nil then
            if type(args.texture) ~= "string" then return { ok = false, error = "`texture` must be a material path string" } end
            pt:SetTexture(args.texture)
        end
        if args.shadows ~= nil then pt:SetEnableShadows(args.shadows and true or false) end
        if args.nocull ~= nil then
            local nc = args.nocull and true or false
            pt:SetNoCull(nc)
            nocullState = nc -- no ProjectedTexture:GetNoCull getter, so report the value we just applied
        end
        if args.target ~= nil then
            local ent = Entity(tonumber(args.target) or -1)
            if IsValid(ent) then pt:SetTargetEntity(ent) end
        end

        pt:Update() -- must be called for any change to take effect

        local ttl
        if args.ttl ~= nil then
            ttl = math.Clamp(tonumber(args.ttl) or 0, 0.05, MAX_TTL)
            MCP:RunFor({
                seconds = ttl,
                stop = function() return not IsValid(MCP._lights[handle]) end,
            }, function()
                local p = MCP._lights[handle]
                if IsValid(p) then p:Remove() end
                MCP._lights[handle] = nil
            end)
        end

        return {
            ok = true,
            realm = MCP.util.RealmName(),
            action = action,
            handle = handle,
            valid = IsValid(pt),
            pos = pt:GetPos(),
            angles = pt:GetAngles(),
            brightness = pt:GetBrightness(),
            fov = pt:GetHorizontalFOV(),
            far_z = pt:GetFarZ(),
            shadows = pt:GetEnableShadows(),
            nocull = nocullState,
            ttl = ttl,
            active_lights = table.Count(MCP._lights),
        }
    end,
})
