-- constraint_find: list an entity's constraint partners and its whole constraint network.
-- The structured read for "what is this welded / no-collided / roped to, and why does it (not)
-- collide or fall through" -- replaces hand-walking constraint.GetTable + GetAllConstrainedEntities
-- in lua_run. Not addon-specific: any constraint/no-collide rig (world-portals frames, contraptions).

local MAX_ROWS = 200

---@param e Entity
local function entRef(e)
    if not IsValid(e) then return nil end
    return { index = e:EntIndex(), class = e:GetClass() }
end

MCP:AddFunction({
    id = "constraint_find",
    description = "List an entity's physics constraints and its whole constraint network -- the structured answer to \"what is this welded/no-collided/roped to?\" and \"why does this prop fall through or not collide?\". Pass `entindex`. Returns `constraints`: one row per constraint the entity is part of, each with its `type` (Weld, NoCollide, Rope, Axis, Ballsocket, ...) and the `partners` (the OTHER entities in that constraint, {index, class}); a `type_counts` tally (e.g. how many NoCollide pairs); and `network`: every entity transitively constrained to this one (constraint.GetAllConstrainedEntities), the full rigid group. NoCollide constraints appear as type \"NoCollide\" rows -- that's the direct answer to a pass-through/fall-through question. Read-only. Lists are capped at 200 with a *_truncated flag and the true *_count.",
    schema = {
        type = "object",
        properties = {
            entindex = { type = "integer", description = "The entity to inspect." },
        },
        required = { "entindex" },
    },
    ---@param args table
    handler = function(args)
        args = args or {}
        if not isnumber(args.entindex) then
            return { ok = false, error = "`entindex` must be a number" }
        end
        local ent = Entity(args.entindex)
        if not IsValid(ent) then
            return { ok = true, valid = false, entindex = args.entindex }
        end

        local constraints, typeCounts = {}, {}
        local records = constraint.GetTable(ent) or {}
        local trueConstraintCount = 0
        for _, rec in ipairs(records) do
            trueConstraintCount = trueConstraintCount + 1
            local ctype = rec.Type or "unknown"
            typeCounts[ctype] = (typeCounts[ctype] or 0) + 1
            if #constraints < MAX_ROWS then
                local partners = {}
                -- Constraint records carry the members as Ent1..Ent4 (most use Ent1/Ent2).
                for i = 1, 4 do
                    local other = rec["Ent" .. i]
                    if IsValid(other) and other ~= ent then
                        partners[#partners + 1] = entRef(other)
                    end
                end
                constraints[#constraints + 1] = { type = ctype, partners = partners }
            end
        end

        local network, trueNetworkCount = {}, 0
        for other in pairs(constraint.GetAllConstrainedEntities(ent) or {}) do
            if IsValid(other) and other ~= ent then
                trueNetworkCount = trueNetworkCount + 1
                if #network < MAX_ROWS then network[#network + 1] = entRef(other) end
            end
        end

        return {
            ok = true,
            valid = true,
            entindex = ent:EntIndex(),
            class = ent:GetClass(),
            constraint_count = trueConstraintCount,
            constraints = constraints,
            constraints_truncated = trueConstraintCount > #constraints,
            type_counts = typeCounts,
            network_count = trueNetworkCount,
            network = network,
            network_truncated = trueNetworkCount > #network,
        }
    end,
})
