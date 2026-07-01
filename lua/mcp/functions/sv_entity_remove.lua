-- entity_remove: remove entities server-side and confirm they're actually gone. The
-- delete-half of the entity family (entity_create spawns, entity_state reads,
-- entity_find locates, entity_set mutates). Server realm. Ungated -- a structured
-- removal is bounded (it never removes players or the worldspawn), not the
-- arbitrary-code power that `unsafe` gates.
--
-- :Remove() is deferred -- the entity goes invalid over the next tick or two -- so a
-- same-call count would be stale. The handler defers and waits (MCP:Settle, the shared
-- bounded-wait helper) until every target is invalid before reporting, mirroring
-- bot_remove's kick-and-confirm.
--
-- Cleanup-tag contract (shared with entity_create): `mcp_spawned` removes every
-- MCP-spawned entity; `tag` removes those whose ent.mcp_spawn_tag matches. Both read
-- the plain fields entity_create wrote on the entity's Lua table.

local REPORT_CAP = 50 -- cap the per-entity detail list; the matched/removed counts stay exact

-- Never remove a player (use bot_remove for bots) or the worldspawn. IsValid is already
-- false for the worldspawn, but the explicit checks make the refusal legible in an error.
local function removable(e)
    if not IsValid(e) then return false, "is not a valid entity" end
    if e:IsPlayer() then return false, "is a player -- use bot_remove for bots" end
    if e:IsWorld() then return false, "is the worldspawn" end
    return true
end

MCP:AddFunction({
    id = "entity_remove",
    requires = { "world_control" },
    description = "Remove entities server-side and wait until they are actually gone before reporting (:Remove is deferred, so a same-call count would be stale). The delete-half of the entity family (entity_create spawns, entity_state reads, entity_find locates, entity_set mutates). Select with EXACTLY ONE of: `index` (one entity by index), `class` (wildcard ok, e.g. \"npc_*\" -- all matching), `model` (model-path substring, e.g. \"watermelon01_chunk\" to clear gib debris), `tag` (every entity_create spawn under that cleanup tag), or `mcp_spawned` (every entity created via entity_create -- the catch-all test-cleanup mode). Never removes players (use bot_remove for bots) or the worldspawn; the bulk modes silently skip them. Returns matched/removed counts, whether removal settled, and the removed entities' identities (capped).",
    schema = {
        type = "object",
        properties = {
            index = {
                type = "integer",
                description = "Remove the single entity at this index. Errors if it is invalid, a player, or the worldspawn.",
            },
            class = {
                type = "string",
                description = "Remove every entity of this class; supports a `*` wildcard (e.g. \"npc_*\", \"prop_physics\"). Matches map-placed entities too -- prefer tag/mcp_spawned to scope to only what you created.",
            },
            model = {
                type = "string",
                description = "Remove every entity whose model path contains this (case-insensitive) substring -- e.g. \"watermelon01_chunk\" to clear gib debris that isn't itself MCP-tagged.",
            },
            tag = {
                type = "string",
                description = "Remove every entity_create-spawned entity carrying this cleanup tag (ent.mcp_spawn_tag).",
            },
            mcp_spawned = {
                type = "boolean",
                description = "Remove every entity created via entity_create (ent.mcp_spawned) -- the catch-all cleanup for test spawns. Does NOT remove engine-spawned debris like gibs (use `model` for those).",
            },
        },
    },
    handler = function(args, ctx)
        args = args or {}

        local sel = {}
        if args.index ~= nil then sel[#sel + 1] = "index" end
        if args.class ~= nil then sel[#sel + 1] = "class" end
        if args.model ~= nil then sel[#sel + 1] = "model" end
        if args.tag ~= nil then sel[#sel + 1] = "tag" end
        if args.mcp_spawned then sel[#sel + 1] = "mcp_spawned" end
        if #sel == 0 then return { ok = false, error = "specify exactly one selector: index, class, model, tag, or mcp_spawned" } end
        if #sel > 1 then return { ok = false, error = "specify exactly one selector, got: " .. table.concat(sel, ", ") } end
        local mode = sel[1]

        local targets = {}
        if mode == "index" then
            local idx = tonumber(args.index)
            if not idx then return { ok = false, error = "`index` must be a number" } end
            local e = Entity(idx)
            local ok, why = removable(e)
            if not ok then return { ok = false, error = "entity " .. tostring(idx) .. " " .. why } end
            targets[1] = e
        elseif mode == "class" then
            local pat = tostring(args.class)
            if pat == "" then return { ok = false, error = "`class` must be a non-empty string" } end
            -- ents.FindByClass handles the `*` wildcard itself (as entity_find relies on).
            for _, e in ipairs(ents.FindByClass(pat)) do
                if removable(e) then targets[#targets + 1] = e end
            end
        elseif mode == "model" then
            local sub = string.lower(tostring(args.model))
            if sub == "" then return { ok = false, error = "`model` must be a non-empty substring" } end
            for _, e in ipairs(ents.GetAll()) do
                if removable(e) then
                    local m = e:GetModel()
                    if m and string.find(string.lower(m), sub, 1, true) then targets[#targets + 1] = e end
                end
            end
        elseif mode == "tag" then
            local want = tostring(args.tag)
            if want == "" then return { ok = false, error = "`tag` must be a non-empty string" } end
            for _, e in ipairs(ents.GetAll()) do
                if removable(e) and e:GetTable().mcp_spawn_tag == want then targets[#targets + 1] = e end
            end
        else -- mcp_spawned
            for _, e in ipairs(ents.GetAll()) do
                if removable(e) and e:GetTable().mcp_spawned then targets[#targets + 1] = e end
            end
        end

        local matched = #targets
        if matched == 0 then
            return {
                ok = true,
                realm = MCP.util.RealmName(),
                selector = mode,
                matched = 0,
                removed = 0,
                settled = true,
                entities = {},
            }
        end

        -- Record identities BEFORE removing (they're unreadable once gone), capped.
        local report = {}
        for i, e in ipairs(targets) do
            if i > REPORT_CAP then break end
            report[i] = { index = e:EntIndex(), class = e:GetClass(), model = e:GetModel() }
        end

        for _, e in ipairs(targets) do e:Remove() end

        -- Wait until every target is invalid before reporting. No dwell needed (gone
        -- stays gone), so stable_for defaults to 0 -- resolve the instant all are gone.
        MCP:Settle({
            seconds = 2,
            check = function()
                for _, e in ipairs(targets) do
                    if IsValid(e) then return false end
                end
                return true
            end,
        }, function(s)
            local stillValid = 0
            for _, e in ipairs(targets) do
                if IsValid(e) then stillValid = stillValid + 1 end
            end
            local result = {
                ok = true,
                realm = MCP.util.RealmName(),
                selector = mode,
                settled = s.settled,
                matched = matched,
                removed = matched - stillValid,
                entities = report,
            }
            if matched > #report then result.entities_truncated = true end
            ctx.respond(result)
        end)

        return ctx.deferred
    end,
})
