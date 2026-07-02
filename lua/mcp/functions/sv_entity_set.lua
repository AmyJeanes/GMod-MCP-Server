-- entity_set: mutate one entity's transform, render and physics state, then confirm.
-- The write-half of the entity family (entity_state reads, entity_find locates,
-- entity_create spawns, entity_remove deletes); the entity counterpart of player_set.
-- Server realm -- entity mutation is server-authoritative. Ungated: a structured mutator
-- can only do what its schema allows, not run arbitrary code.
--
-- Every arg optional except `index`; supply any subset (at least one mutation). The
-- physics mutations (frozen/velocity/mass/gravity) need a valid PhysObj -- a requested
-- one that can't apply is reported in `skipped` while the rest still take effect, rather
-- than failing the whole call. Players are refused (use player_set, which owns pose/holds
-- and keeps prediction consistent). Colour/freeze primitives are shared with entity_create
-- via MCP.entity.
--
-- Settle-and-confirm only when `pos` is set without an explicit `velocity` (the
-- placement-confirm case, like player_set): defer until the entity comes to rest and
-- report where it actually ended up. A requested velocity means intentional motion, so
-- there's nothing to wait for -- respond immediately.

local SETTLE_CAP = 1.0  -- give up waiting for stillness after this long; report as-is
local STILL_DWELL = 0.1 -- velocity must stay at-rest this long to count as settled
local STILL_SPEED = 5   -- speed (u/s) below which the entity counts as at rest

local function parseVec3(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1] or t.x), tonumber(t[2] or t.y), tonumber(t[3] or t.z)
    if not (x and y and z) then return nil end
    return Vector(x, y, z)
end

local function parseAngles(t)
    if type(t) ~= "table" then return nil end
    local p, y, r = tonumber(t[1] or t.p), tonumber(t[2] or t.y), tonumber(t[3] or t.r)
    if not (p and y and r) then return nil end
    return Angle(p, y, r)
end

-- A zero-extent hull trace at the rest position: is the entity embedded in world/solid?
-- Axis-aligned on the OBB (ignores rotation), so it's a best-effort flag like player_set's.
local function inSolid(ent, pos)
    local tr = util.TraceHull({
        start = pos,
        endpos = pos,
        mins = ent:OBBMins(),
        maxs = ent:OBBMaxs(),
        filter = ent,
        mask = MASK_SOLID --[[@as MASK]],
    })
    return tr.StartSolid == true or tr.AllSolid == true
end

MCP:AddFunction({
    id = "entity_set",
    requires = { "world_control" },
    description = "Mutate one entity's transform, render and physics state by index, then confirm. The write-half of the entity family (entity_state reads, entity_find locates, entity_create spawns, entity_remove deletes) -- the entity counterpart of player_set. Every arg is optional except `index`; supply any subset (at least one mutation). Transform: `pos` [x,y,z], `angles` [pitch,yaw,roll]. Render: `color` [r,g,b(,a)] (alpha<255 -> translucent render mode), `material` (\"\" clears), `nodraw`, `skin`, `model_scale`. Collision/hierarchy: `collision_group` (COLLISION_GROUP_* name), `movetype` (MOVETYPE_* name -- use MOVETYPE_NONE to pin an NPC, which ignores physics freeze), `parent` (entindex to parent to, or -1 to unparent). Physics (need a valid physics object -- a requested physics mutation that can't apply is reported in `skipped`, the rest still apply): `frozen` (true = freeze in place / disable motion, false = unfreeze + wake), `velocity` [x,y,z], `mass`, `gravity`, `wake` (force the physics object awake). Players are refused -- use player_set for players (it owns pose/holds and keeps prediction consistent). When `pos` is set without a `velocity`, the call waits for the entity to settle and reports where it actually came to rest (settled / moved_after_place / in_solid); a requested velocity means intentional motion, so it returns immediately.",
    schema = {
        type = "object",
        properties = {
            index = {
                type = "integer",
                description = "Index of the entity to mutate (as returned by entity_find/entity_create). Errors if invalid or a player.",
            },
            pos = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Teleport to this [x, y, z] world position.",
            },
            angles = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Set orientation to [pitch, yaw, roll].",
            },
            color = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 4,
                description = "Set render colour [r, g, b] or [r, g, b, a], each 0-255. An alpha below 255 switches to a translucent render mode.",
            },
            material = {
                type = "string",
                description = "Override the entity's material (an empty string clears the override).",
            },
            nodraw = {
                type = "boolean",
                description = "Hide (true) or show (false) the entity's rendering. Does not affect collision.",
            },
            skin = {
                type = "integer", minimum = 0,
                description = "Set the model skin index.",
            },
            model_scale = {
                type = "number",
                description = "Set the model render scale (1 = default). Must be greater than 0.",
            },
            collision_group = {
                type = "string",
                description = "Set the collision group by COLLISION_GROUP_* constant name (e.g. \"COLLISION_GROUP_WORLD\", \"COLLISION_GROUP_DEBRIS\", \"COLLISION_GROUP_WEAPON\", \"COLLISION_GROUP_NONE\").",
            },
            movetype = {
                type = "string",
                description = "Set the movetype by MOVETYPE_* constant name (e.g. \"MOVETYPE_NONE\", \"MOVETYPE_VPHYSICS\", \"MOVETYPE_NOCLIP\"). NPCs ignore physics freeze/EnableMotion, so use MOVETYPE_NONE to pin one in place.",
            },
            parent = {
                type = "integer",
                description = "Parent this entity to the entity at this index so it follows the parent's movement. Use -1 to clear the parent (unparent). Cannot parent an entity to itself.",
            },
            frozen = {
                type = "boolean",
                description = "true = freeze in place (disable physics motion and sleep); false = unfreeze and wake. Needs a physics object.",
            },
            velocity = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Set the physics linear velocity to [x, y, z] and wake the object. Needs a physics object; no-op while frozen.",
            },
            mass = {
                type = "number",
                description = "Set the physics mass (kg), clamped to (0, 50000]. Needs a physics object.",
            },
            gravity = {
                type = "boolean",
                description = "Enable (true) or disable (false) gravity on the physics object. Needs a physics object.",
            },
            wake = {
                type = "boolean",
                description = "Wake the physics object (PhysObj:Wake) to force it to re-evaluate -- e.g. to shift a sleep-cached shadow after enabling motion. Needs a physics object; only true acts (false is a no-op).",
            },
        },
        required = { "index" },
    },
    ---@param args table
    handler = function(args, ctx)
        args = args or {}

        local idx = tonumber(args.index)
        if not idx then return { ok = false, error = "`index` must be a number" } end
        local ent = Entity(idx)
        if not IsValid(ent) then return { ok = false, error = "entity " .. tostring(idx) .. " is not a valid entity" } end
        if ent:IsPlayer() then return { ok = false, error = "entity " .. tostring(idx) .. " is a player -- use player_set for players" } end

        -- Parse and validate everything up front so a bad arg fails before any mutation.
        local pos, angles, col, velocity
        if args.pos ~= nil then
            pos = parseVec3(args.pos)
            if not pos then return { ok = false, error = "`pos` must be a 3-number array [x, y, z]" } end
        end
        if args.angles ~= nil then
            angles = parseAngles(args.angles)
            if not angles then return { ok = false, error = "`angles` must be a 3-number array [pitch, yaw, roll]" } end
        end
        if args.color ~= nil then
            local c, cerr = MCP.entity.ParseColor(args.color)
            if not c then return { ok = false, error = "`color` " .. cerr } end
            col = c
        end
        if args.velocity ~= nil then
            velocity = parseVec3(args.velocity)
            if not velocity then return { ok = false, error = "`velocity` must be a 3-number array [x, y, z]" } end
        end
        if args.model_scale ~= nil and (tonumber(args.model_scale) or 0) <= 0 then
            return { ok = false, error = "`model_scale` must be greater than 0" }
        end

        local collisionGroup, movetype
        if args.collision_group ~= nil then
            local cg, cgErr = MCP.util.ResolveEnum("COLLISION_GROUP_", args.collision_group)
            if cgErr then return { ok = false, error = "`collision_group` " .. cgErr } end
            collisionGroup = cg
        end
        if args.movetype ~= nil then
            local mt, mtErr = MCP.util.ResolveEnum("MOVETYPE_", args.movetype)
            if mtErr then return { ok = false, error = "`movetype` " .. mtErr } end
            movetype = mt
        end

        -- parent: index >=1 to parent, -1 (or any <=0) to unparent.
        local parentEnt, unparent
        if args.parent ~= nil then
            local pidx = tonumber(args.parent)
            if not pidx then return { ok = false, error = "`parent` must be an entity index, or -1 to unparent" } end
            if pidx <= 0 then
                unparent = true
            elseif math.floor(pidx) == idx then
                return { ok = false, error = "cannot parent entity " .. idx .. " to itself" }
            else
                parentEnt = Entity(math.floor(pidx))
                if not IsValid(parentEnt) then return { ok = false, error = "`parent` entity " .. tostring(pidx) .. " is not valid" } end
            end
        end

        local hasAction = pos or angles or col or velocity
            or args.material ~= nil or args.nodraw ~= nil or args.skin ~= nil
            or args.model_scale ~= nil or args.frozen ~= nil or args.mass ~= nil
            or args.gravity ~= nil or collisionGroup ~= nil or movetype ~= nil
            or args.parent ~= nil or args.wake == true
        if not hasAction then
            return { ok = false, error = "entity_set needs at least one mutation (pos, angles, color, material, nodraw, skin, model_scale, collision_group, movetype, parent, frozen, velocity, mass, gravity, wake)" }
        end

        local startPos = ent:GetPos()
        local applied, skipped = {}, {}

        -- Non-physics mutations always apply.
        if pos then ent:SetPos(pos) applied[#applied + 1] = "pos" end
        if angles then ent:SetAngles(angles) applied[#applied + 1] = "angles" end
        if col then MCP.entity.ApplyColor(ent, col) applied[#applied + 1] = "color" end
        if args.material ~= nil then ent:SetMaterial(tostring(args.material)) applied[#applied + 1] = "material" end
        if args.nodraw ~= nil then ent:SetNoDraw(args.nodraw == true) applied[#applied + 1] = "nodraw" end
        if args.skin ~= nil then ent:SetSkin(math.floor(tonumber(args.skin) or 0)) applied[#applied + 1] = "skin" end
        if args.model_scale ~= nil then ent:SetModelScale(tonumber(args.model_scale), 0) applied[#applied + 1] = "model_scale" end
        if collisionGroup ~= nil then ent:SetCollisionGroup(collisionGroup) applied[#applied + 1] = "collision_group" end
        if movetype ~= nil then ent:SetMoveType(movetype) applied[#applied + 1] = "movetype" end
        if unparent then ent:SetParent() applied[#applied + 1] = "parent"
        elseif parentEnt then ent:SetParent(parentEnt) applied[#applied + 1] = "parent" end

        -- Physics mutations need a valid PhysObj; record requested-but-inapplicable ones.
        local phys = ent:GetPhysicsObject()
        local function physMutate(name, fn)
            if IsValid(phys) then fn() applied[#applied + 1] = name else skipped[name] = "no physics object" end
        end
        if args.mass ~= nil then physMutate("mass", function() phys:SetMass(math.Clamp(tonumber(args.mass), 0.1, 50000)) end) end
        if args.gravity ~= nil then physMutate("gravity", function() phys:EnableGravity(args.gravity == true) end) end
        if velocity then physMutate("velocity", function() phys:SetVelocity(velocity) phys:Wake() end) end
        if args.wake == true then physMutate("wake", function() phys:Wake() end) end
        -- frozen last so a freeze wins over a same-call velocity (final state = frozen).
        if args.frozen ~= nil then
            local frozen = args.frozen == true
            if MCP.entity.SetFrozen(ent, frozen) then applied[#applied + 1] = "frozen" else skipped.frozen = "no physics object" end
        end

        local function snapshot(extra)
            local p = ent:GetPhysicsObject()
            local r = {
                ok = true,
                realm = MCP.util.RealmName(),
                index = ent:EntIndex(),
                class = ent:GetClass(),
                applied = applied,
                pos = ent:GetPos(),
                angles = ent:GetAngles(),
                velocity = ent:GetVelocity(),
                movetype = MCP.util.DecodeEnum("MOVETYPE_", ent:GetMoveType()),
                collision_group = MCP.util.DecodeEnum("COLLISION_GROUP_", ent:GetCollisionGroup()),
                has_physics = IsValid(p),
            }
            local par = ent:GetParent()
            r.parent = IsValid(par) and par:EntIndex() or false
            if next(skipped) ~= nil then r.skipped = skipped end
            if IsValid(p) then
                r.mass = p:GetMass()
                r.frozen = not p:IsMotionEnabled()
            end
            if extra then for k, v in pairs(extra) do r[k] = v end end
            return r
        end

        -- Confirm a placement: wait for rest, then report where it landed. Gate on
        -- velocity (not position) so a from-rest fall can't false-settle its first frames.
        if pos and not velocity then
            MCP:Settle({
                seconds = SETTLE_CAP,
                stable_for = STILL_DWELL,
                check = function() return IsValid(ent) and ent:GetVelocity():Length() < STILL_SPEED end,
            }, function(s)
                if not IsValid(ent) then
                    ctx.respond({ ok = false, error = "entity became invalid during settle" })
                    return
                end
                local endPos = ent:GetPos()
                ctx.respond(snapshot({
                    settled = s.settled,
                    settle_time = math.Round(s.elapsed, 2),
                    moved_after_place = math.Round(endPos:Distance(pos), 1),
                    in_solid = inSolid(ent, endPos),
                    requested_pos = { math.Round(pos.x, 1), math.Round(pos.y, 1), math.Round(pos.z, 1) },
                    start_pos = { math.Round(startPos.x, 1), math.Round(startPos.y, 1), math.Round(startPos.z, 1) },
                }))
            end)
            return ctx.deferred
        end

        return snapshot()
    end,
})
