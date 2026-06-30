-- entity_create: spawn one entity server-side (Create -> SetModel -> SetPos ->
-- Spawn -> Activate), optionally frozen and coloured, tagged for later cleanup.
-- The create-half of the entity family (entity_state reads one, entity_find locates
-- many, entity_set mutates, entity_remove deletes). Server realm -- entity creation
-- is server-authoritative. Ungated: a structured spawn can only place/freeze/colour
-- what the schema allows, not run arbitrary code.
--
-- Cleanup contract (shared with entity_remove): every spawned entity gets
-- ent.mcp_spawned = true on its Lua table, plus ent.mcp_spawn_tag = <tag> when a tag
-- is given. entity_remove enumerates ents.GetAll() and matches those fields, so there
-- is no registry to leak. (The freeze/colour helpers below move to a shared lib once
-- entity_set is the second consumer; inline here while there's only one.)

-- A prop_physics with a bad or empty model spawns with a NULL physics object -- the
-- authoritative "invalid model" signal. Only these classes get that guard; prop_dynamic,
-- point entities, NPCs etc. legitimately have no server-side physics object.
local PHYSICS_PROP_CLASSES = {
    prop_physics = true,
    prop_physics_multiplayer = true,
}

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

-- Colour parsing/clamping and the freeze/colour-apply primitives are shared with
-- entity_set via MCP.entity (lua/mcp/libraries/libraries/sv_entity.lua).

MCP:AddFunction({
    id = "entity_create",
    description = "Spawn one entity server-side -- Create, SetModel, SetPos, Spawn, Activate -- optionally frozen and coloured, and tagged for later cleanup by entity_remove. The create-half of the entity family (entity_state reads one, entity_find locates many, entity_set mutates, entity_remove deletes). Defaults to a frozen prop_physics so it stays exactly where placed; pass frozen:false to let it obey gravity immediately. prop_* classes require a `model`, validated against mounted game content before spawning, with a post-spawn physics check that rejects (and removes) a model that loads no physics object. Returns the new entity's index, class, resting pose and mass -- drill in with entity_state or reposition with entity_set.",
    schema = {
        type = "object",
        properties = {
            class = {
                type = "string",
                description = "Entity class to create (default \"prop_physics\"). prop_* classes require `model`.",
            },
            model = {
                type = "string",
                description = "Model path, e.g. \"models/props_c17/oildrum001.mdl\". Required for prop_* classes. Validated against mounted game content; an unknown model is rejected before spawning.",
            },
            pos = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "World position [x, y, z] to spawn at.",
            },
            angles = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Orientation [pitch, yaw, roll]. Defaults to [0, 0, 0].",
            },
            frozen = {
                type = "boolean",
                description = "Freeze physics on spawn so the entity stays exactly where placed (default true). Set false to let it obey gravity/physics immediately. No effect on entities without a physics object.",
            },
            color = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 4,
                description = "Render colour [r, g, b] or [r, g, b, a], each 0-255. An alpha below 255 switches the entity to a translucent render mode.",
            },
            tag = {
                type = "string",
                description = "Optional cleanup tag. Every spawned entity is marked MCP-spawned; a tag additionally groups it so entity_remove can delete just this group.",
            },
        },
        required = { "pos" },
    },
    handler = function(args)
        args = args or {}

        local class = args.class
        if class == nil then class = "prop_physics" end
        if type(class) ~= "string" or class == "" then
            return { ok = false, error = "`class` must be a non-empty string" }
        end

        local pos = parseVec3(args.pos)
        if not pos then return { ok = false, error = "`pos` must be a 3-number array [x, y, z]" } end

        local angles
        if args.angles ~= nil then
            angles = parseAngles(args.angles)
            if not angles then return { ok = false, error = "`angles` must be a 3-number array [pitch, yaw, roll]" } end
        end

        local col
        if args.color ~= nil then
            local c, cerr = MCP.entity.ParseColor(args.color)
            if not c then return { ok = false, error = "`color` " .. cerr } end
            col = c
        end

        local model = args.model
        if model ~= nil then
            if type(model) ~= "string" or model == "" then
                return { ok = false, error = "`model` must be a model path string (e.g. models/props_c17/oildrum001.mdl)" }
            end
            if not file.Exists(model, "GAME") then
                return { ok = false, error = "model not found: " .. model .. " (no such .mdl on a mounted game path)" }
            end
        end

        local needsModel = string.sub(class, 1, 5) == "prop_"
        if needsModel and not model then
            return { ok = false, error = "`model` is required for prop classes (" .. class .. ")" }
        end

        local ent = ents.Create(class)
        if not IsValid(ent) then
            return { ok = false, error = "could not create an entity of class '" .. class .. "' (unknown or non-spawnable class)" }
        end

        if model then ent:SetModel(model) end
        ent:SetPos(pos)
        if angles then ent:SetAngles(angles) end
        ent:Spawn()
        ent:Activate()

        if not IsValid(ent) then
            return { ok = false, error = "entity became invalid immediately after spawn (class '" .. class .. "' may have rejected these parameters)" }
        end

        -- Authoritative bad-model guard: a physics prop with no valid PhysObj means the
        -- model failed to load. Remove it so a broken prop isn't left in the world.
        if PHYSICS_PROP_CLASSES[class] and not IsValid(ent:GetPhysicsObject()) then
            ent:Remove()
            return { ok = false, error = "model '" .. tostring(model) .. "' spawned with no physics object (not a valid physics model)" }
        end

        local frozen = args.frozen ~= false -- default true
        local hasPhys = MCP.entity.SetFrozen(ent, frozen)
        if col then MCP.entity.ApplyColor(ent, col) end

        -- Cleanup tag (contract with entity_remove): mark every spawned entity, plus an
        -- optional named tag for selective removal.
        local tbl = ent:GetTable()
        tbl.mcp_spawned = true
        local tag
        if args.tag ~= nil and tostring(args.tag) ~= "" then
            tag = tostring(args.tag)
            tbl.mcp_spawn_tag = tag
        end

        local phys = ent:GetPhysicsObject()
        local result = {
            ok = true,
            realm = MCP.util.RealmName(),
            index = ent:EntIndex(),
            creation_id = ent:GetCreationID(),
            class = ent:GetClass(),
            pos = ent:GetPos(),
            angles = ent:GetAngles(),
            frozen = hasPhys and frozen,
            has_physics = IsValid(phys),
        }
        if model then result.model = ent:GetModel() end
        if col then result.color = col end
        if tag then result.tag = tag end
        if IsValid(phys) then result.mass = phys:GetMass() end
        return result
    end,
})
