-- entity_state: nil-safe structured snapshot of ONE entity by index. The read-half
-- of the entity family (entity_find locates, entity_set mutates). Replaces the
-- hand-rolled string.format/util.TableToJSON entity dumps that recur across every
-- addon -- and the IsValid(e) and e:Foo() guard boilerplate that was their #1 error
-- source. A dead/recycled index returns valid=false rather than throwing (index
-- reuse after a respawn is the common case, not the exception). Both realms: _sv
-- reads server state, _cl client state -- they legitimately differ for dormant or
-- not-yet-networked entities. Ungated (structured read).

-- Enum decode (MCP.util.DecodeEnum) and the pcall getter factory (MCP.util.Getter) are
-- shared read-tool primitives -- both lazy/define-only so registration stays generator-safe.

MCP:AddFunction({
    id = "entity_state",
    description = "Nil-safe structured snapshot of one entity by index -- identity, transform, render (incl. effects flags), collision (solid + FSOLID flags + collision bounds), OBB bounds, hierarchy (incl. parent-local transform when parented), physics and health in a single read. A dead or recycled index returns valid=false instead of erroring (index reuse after respawns is common), and always echoes the index so the caller can confirm the right entity. Set include_table to also dump the entity's Lua table (ent:GetTable(), depth-capped) -- where addon dynamic state such as TARDIS `.data` lives; include_constraints for welds/ropes/etc. on the entity; include_nw_vars for the generic NW/NW2 networked-var bags (distinct from a SENT's SetupDataTables accessors). Pointed at a player this returns only the generic entity fields plus is_player; use player_state for eye/duck/anim/weapon. Locate entities with entity_find. Runs in both realms (_sv server state, _cl client state -- they can differ for dormant/unnetworked entities).",
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
            include_constraints = {
                type = "boolean",
                description = "Also include `constraints`: the constraints attached to this entity (constraint.GetTable -- welds, ropes, axes, etc.), depth-capped. Off by default.",
            },
            include_nw_vars = {
                type = "boolean",
                description = "Also include `nw_vars`: the generic networked-var bags (`nw` = GetNWVarTable, `nw2` = GetNW2VarTable), each included only when non-empty. These are the SetNW*/SetNW2* stores, NOT a scripted entity's SetupDataTables accessors (those need the entity's own getters -- see include_table). Off by default.",
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

        local get = MCP.util.Getter(ent)
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

            movetype = MCP.util.DecodeEnum("MOVETYPE_", get("GetMoveType")),
            solid = MCP.util.DecodeEnum("SOLID_", get("GetSolid")),
            collision_group = MCP.util.DecodeEnum("COLLISION_GROUP_", get("GetCollisionGroup")),

            bounds = {
                obb_mins = get("OBBMins"),
                obb_maxs = get("OBBMaxs"),
                obb_center = get("OBBCenter"),
            },

            health = get("Health"),
        }

        -- effects (EF_* bitmask, e.g. EF_BONEMERGE/EF_NODRAW): only when set, to stay lean.
        local eff = get("GetEffects")
        if isnumber(eff) and eff ~= 0 then r.effects = MCP.util.DecodeBits("EF_", eff) end
        -- solid flags (FSOLID_*): the collision behaviour distinct from the SOLID_ type.
        local sflags = get("GetSolidFlags")
        if isnumber(sflags) then
            local decoded = MCP.util.DecodeBits("FSOLID_", sflags)
            if decoded and #decoded > 0 then r.solid_flags = decoded end
        end
        -- collision bounds (GetCollisionBounds returns min,max) -- the AABB used for
        -- collision, which can differ from the render OBB above; include only when it does.
        local okCB, cbMin, cbMax = pcall(ent.GetCollisionBounds, ent)
        if okCB and isvector(cbMin) and isvector(cbMax) and (cbMin ~= r.bounds.obb_mins or cbMax ~= r.bounds.obb_maxs) then
            r.collision_bounds = { mins = cbMin, maxs = cbMax }
        end

        -- name: targetname for entities, Nick for players; omit when empty (most props).
        local nm = ent:IsPlayer() and ent:Nick() or get("GetName")
        if nm and nm ~= "" then r.name = nm end

        local vel = get("GetVelocity")
        if vel then
            r.velocity = vel
            r.speed = vel:Length()
        end

        -- parent/owner serialize to {class,index,valid} via the global serializer;
        -- omit when absent so a NULL doesn't render as a phantom relationship. When parented,
        -- parent_local is the transform relative to the parent (what SetParent preserves).
        local par = get("GetParent")
        if IsValid(par) then
            r.parent = par
            r.parent_local = { pos = get("GetLocalPos"), angles = get("GetLocalAngles") }
        end
        local own = get("GetOwner")
        if IsValid(own) then r.owner = own end
        local children = get("GetChildren")
        if children then r.children_count = #children end

        -- Physics reads come off the PhysObj, which is NULL for many entities (and
        -- after a model fails to load) -- guard the whole block; omit when absent.
        -- phys pos/angles differ from the entity's for keyframed/shadow objects.
        local phys = get("GetPhysicsObject")
        if IsValid(phys) then
            local pget = MCP.util.Getter(phys)
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

        -- Opt-in constraints (welds/ropes/etc. on this entity) -- can be large, so off by default.
        if args.include_constraints then
            local okC, ct = pcall(constraint.GetTable, ent)
            if okC and istable(ct) then
                r.constraints = MCP.util.Serialize(ct, { max_depth = 4, max_nodes = 800 })
            end
        end

        -- Opt-in networked vars: generic NW/NW2 bags (SetNW*/SetNW2*), distinct from a SENT's
        -- SetupDataTables accessors (which need the entity's own getters -- see entity_table).
        -- Both included when non-empty; most props carry neither.
        if args.include_nw_vars then
            local nw = {}
            local legacy = get("GetNWVarTable")
            if istable(legacy) and next(legacy) ~= nil then nw.nw = MCP.util.Serialize(legacy, { max_depth = 4, max_nodes = 800 }) end
            local nw2 = get("GetNW2VarTable")
            if istable(nw2) and next(nw2) ~= nil then nw.nw2 = MCP.util.Serialize(nw2, { max_depth = 4, max_nodes = 800 }) end
            if next(nw) ~= nil then r.nw_vars = nw end
        end

        return r
    end,
})
