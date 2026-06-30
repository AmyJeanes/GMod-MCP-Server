-- entity_state: nil-safe structured snapshot of ONE entity by index. The read-half
-- of the entity family (entity_find locates, entity_set mutates). Replaces the
-- hand-rolled string.format/util.TableToJSON entity dumps that recur across every
-- addon -- and the IsValid(e) and e:Foo() guard boilerplate that was their #1 error
-- source. A dead/recycled index returns valid=false rather than throwing (index
-- reuse after a respawn is the common case, not the exception). Both realms: _sv
-- reads server state, _cl client state -- they legitimately differ for dormant or
-- not-yet-networked entities. Ungated (structured read).

-- Decode enum ints to their constant names so the dump is self-explaining
-- (movetype "MOVETYPE_NONE" reads better than 11). Maps are built lazily on first
-- use, not at file load -- the headless tool-list generator runs this file's
-- registration under a minimal stub env without isnumber/the enum globals, and
-- only handlers (which run solely in-game) should touch them. Falls back to the
-- raw int for an unknown value.
local enumMaps
local function ensureEnumMaps()
    if enumMaps then return enumMaps end
    local function build(prefix)
        local m = {}
        for k, v in pairs(_G) do
            if isnumber(v) and string.sub(k, 1, #prefix) == prefix then m[v] = k end
        end
        return m
    end
    enumMaps = {
        movetype = build("MOVETYPE_"),
        solid = build("SOLID_"),
        cgroup = build("COLLISION_GROUP_"),
    }
    return enumMaps
end

local function decode(map, v)
    if v == nil then return nil end
    return map[v] or v
end

-- Feature-test + pcall a getter: not every method exists on every entity or in
-- every realm (GetModelRenderBounds is nil server-side; a NULL physobj throws),
-- and some getters return *nothing* (not nil), which crashes naive serialization.
-- nil on absence/error/no-return -- the caller just omits the field.
local function makeGetter(obj)
    return function(method, ...)
        local fn = obj[method]
        if not isfunction(fn) then return nil end
        local ok, res = pcall(fn, obj, ...)
        if not ok then return nil end
        return res
    end
end

MCP:AddFunction({
    id = "entity_state",
    description = "Nil-safe structured snapshot of one entity by index -- identity, transform, render, collision, bounds, hierarchy, physics and health in a single read. A dead or recycled index returns valid=false instead of erroring (index reuse after respawns is common), and always echoes the index so the caller can confirm the right entity. Set include_table to also dump the entity's Lua table (ent:GetTable(), depth-capped) -- where addon dynamic state such as TARDIS `.data` lives. Pointed at a player this returns only the generic entity fields plus is_player; use player_state for eye/duck/anim/weapon. Locate entities with entity_find. Runs in both realms (_sv server state, _cl client state -- they can differ for dormant/unnetworked entities).",
    schema = {
        type = "object",
        properties = {
            entindex = {
                type = "integer",
                description = "Index of the entity to inspect (as returned by EntIndex or a previous tool). 0 is the worldspawn (readable, reports valid=false).",
            },
            include_table = {
                type = "boolean",
                description = "Also include `entity_table`: a depth-capped dump of the entity's Lua table (ent:GetTable()). Off by default -- it can be large and noisy (functions, merged addon definitions), but it is where addon dynamic state lives (e.g. TARDIS `.data`). Lands nested, not flattened.",
            },
        },
        required = { "entindex" },
    },
    handler = function(args)
        args = args or {}
        local idx = tonumber(args.entindex)
        if not idx then return { ok = false, error = "`entindex` must be a number" } end

        local ent = Entity(idx)

        -- Probe GetClass under pcall rather than gating on IsValid: a truly-dead
        -- index throws (-> valid=false), while the worldspawn is readable yet has
        -- IsValid false (a GMod quirk), so it must take the full-gather path.
        local gotClass, class = pcall(ent.GetClass, ent)
        if not gotClass then
            return { ok = true, index = idx, valid = false }
        end

        local get = makeGetter(ent)
        local maps = ensureEnumMaps()
        local r = {
            ok = true,
            index = idx,
            valid = IsValid(ent),
            class = class,
            creation_id = get("GetCreationID"),
            is_player = ent:IsPlayer(),
            is_npc = ent:IsNPC(),
            is_weapon = ent:IsWeapon(),
            is_ragdoll = ent:IsRagdoll(),

            pos = get("GetPos"),
            angles = get("GetAngles"),
            world_center = get("WorldSpaceCenter"),

            model = get("GetModel"),
            model_scale = get("GetModelScale"),
            skin = get("GetSkin"),
            color = get("GetColor"),
            material = get("GetMaterial"),
            nodraw = get("GetNoDraw"),
            dormant = get("IsDormant"),

            movetype = decode(maps.movetype, get("GetMoveType")),
            solid = decode(maps.solid, get("GetSolid")),
            collision_group = decode(maps.cgroup, get("GetCollisionGroup")),

            bounds = {
                obb_mins = get("OBBMins"),
                obb_maxs = get("OBBMaxs"),
                obb_center = get("OBBCenter"),
            },

            health = get("Health"),
        }

        -- name: targetname for entities, Nick for players; omit when empty (most props).
        local nm = ent:IsPlayer() and ent:Nick() or get("GetName")
        if nm and nm ~= "" then r.name = nm end

        local vel = get("GetVelocity")
        if vel then
            r.velocity = vel
            r.speed = vel:Length()
        end

        -- parent/owner serialize to {class,index,valid} via the global serializer;
        -- omit when absent so a NULL doesn't render as a phantom relationship.
        local par = get("GetParent")
        if IsValid(par) then r.parent = par end
        local own = get("GetOwner")
        if IsValid(own) then r.owner = own end
        local children = get("GetChildren")
        if children then r.children_count = #children end

        -- Physics reads come off the PhysObj, which is NULL for many entities (and
        -- after a model fails to load) -- guard the whole block; omit when absent.
        -- phys pos/angles differ from the entity's for keyframed/shadow objects.
        local phys = get("GetPhysicsObject")
        if IsValid(phys) then
            local pget = makeGetter(phys)
            r.physics = {
                valid = true,
                mass = pget("GetMass"),
                motion_enabled = pget("IsMotionEnabled"),
                asleep = pget("IsAsleep"),
                pos = pget("GetPos"),
                angles = pget("GetAngles"),
                velocity = pget("GetVelocity"),
                angular_velocity = pget("GetAngleVelocity"),
            }
        end

        if args.include_table then
            local okT, tbl = pcall(ent.GetTable, ent)
            if okT and istable(tbl) then
                r.entity_table = MCP.util.Serialize(tbl, { max_depth = 5, max_nodes = 1500 })
            end
        end

        return r
    end,
})
