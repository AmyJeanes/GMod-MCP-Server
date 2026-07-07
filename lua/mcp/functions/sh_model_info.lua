-- model_info: structured info about a model ASSET without spawning a prop. Backed by
-- util.GetModelInfo (a pure file query -- no entity, no spawn), so it's synchronous and
-- realm-identical (the model file is the same on both realms). Replaces the
-- spawn-prop -> read OBBMins/OBBMaxs -> remove idiom for "how big is this model / what is in
-- it". util.GetModelInfo's HullMin/HullMax matches a spawned prop's OBBMins/OBBMaxs, so the
-- bounds are the same you'd get from a throwaway prop, without the throwaway prop.
--
-- Nil-safety: util.GetModelInfo returns a (garbage) table even for a model that does not
-- exist, so file.Exists is the real existence gate -- a missing model is reported as data
-- (exists=false), never an error or garbage bounds.

local MATERIAL_CAP = 40
local SEQ_NAME_CAP = 25
local ATT_NAME_CAP = 40

-- Project an array of strings (Materials) or {Name=...} tables (Sequences/Attachments) to a
-- capped list of names; returns the list and whether it was truncated. Drops the heavy fields
-- (an Attachment's Offset matrix string, a Sequence's Events) -- names are what's useful.
---@param arr table
---@param cap number
local function names(arr, cap)
    local out, truncated = {}, false
    if istable(arr) then
        for k = 1, #arr do
            if #out >= cap then truncated = true break end
            local v = arr[k]
            if isstring(v) then
                out[#out + 1] = v
            elseif istable(v) and v.Name then
                out[#out + 1] = v.Name
            end
        end
    end
    return out, truncated
end

-- Measure a model's RENDER bounds via a throwaway entity. util.GetModelInfo has no render
-- bounds, and a custom model's render bounds (the frustum-cull box) can exceed its collision
-- hull. Server: an un-Spawned prop_dynamic -- GetModelRenderBounds works after SetModel, before
-- Spawn, so there's no networking/flicker. Client: a ClientsideModel. Precache first (server
-- GetModelRenderBounds returns nil/degenerate for an unprecached model).
---@param model string
local function measureRenderBounds(model)
    util.PrecacheModel(model)
    local e
    if CLIENT then
        e = ClientsideModel(model)
    else
        e = ents.Create("prop_dynamic")
        if IsValid(e) then e:SetModel(model) end
    end
    if not IsValid(e) then return nil end
    local mins, maxs = e:GetModelRenderBounds()
    e:Remove()
    if not (isvector(mins) and isvector(maxs)) then return nil end
    return mins, maxs
end

MCP:AddFunction({
    id = "model_info",
    description = "Structured info about a model ASSET without spawning a prop -- read straight from the model file via util.GetModelInfo (no entity, no spawn), so it is synchronous and realm-identical. Replaces the spawn-prop -> read OBBMins/OBBMaxs -> remove idiom. Pass `model` (a path like \"models/props_c17/oildrum001.mdl\"). Returns `bounds` {mins, maxs, size, center} -- the model's hull bounding box, which matches a spawned prop's OBBMins/OBBMaxs, so it is the size you'd get by spawning and reading OBB, without the spawn -- plus skin_count, bone_count, mesh_count, surface_prop (the physics surface, e.g. \"metal_barrel\"), static_prop, eye_position, material_count + materials (capped name list), sequence_count + sequences (capped animation-name list), and attachment_count + attachments (capped name list); the *_truncated flags appear when a list was capped. Set `include_render_bounds` to also get `render_bounds` {mins,maxs,size,center} -- the model's RENDER bounds (the frustum-cull box), which for a custom model can exceed the collision hull; this one field is measured via a brief throwaway entity (so it is not spawn-free like the rest, and may differ slightly between realms). A missing model returns exists=false (valid data, not an error) -- util.GetModelInfo returns garbage for a nonexistent model, so existence is gated on file.Exists. Does NOT include mass (a runtime physics property -- spawn one and use entity_state) or bodygroups (need an entity). Read-only; runs in both realms with identical results.",
    schema = {
        type = "object",
        properties = {
            model = {
                type = "string",
                description = "Model path, e.g. \"models/props_c17/oildrum001.mdl\" (relative to the game's content root, as Entity:SetModel takes).",
            },
            include_render_bounds = {
                type = "boolean",
                description = "Also measure the model's RENDER bounds (GetModelRenderBounds -- the frustum-cull box, which can exceed the collision hull for custom models) via a brief throwaway entity. Unlike the rest of this tool, this path DOES create a transient entity and can differ slightly between realms. Default false.",
            },
        },
        required = { "model" },
    },
    handler = function(args)
        args = args or {}
        local model = args.model
        if type(model) ~= "string" or model == "" then
            return { ok = false, error = "`model` must be a non-empty model path" }
        end

        if not file.Exists(model, "GAME") then
            return { ok = true, realm = MCP.util.RealmName(), model = model, exists = false }
        end

        local i = util.GetModelInfo(model)
        if not istable(i) then
            return { ok = true, realm = MCP.util.RealmName(), model = model, exists = true, info_available = false }
        end

        local out = {
            ok = true,
            realm = MCP.util.RealmName(),
            model = model,
            exists = true,
            skin_count = i.SkinCount,
            bone_count = i.BoneCount,
            mesh_count = i.MeshCount,
            surface_prop = i.SurfacePropName,
            static_prop = i.StaticProp,
            eye_position = i.EyePosition,
            material_count = i.MaterialCount,
            sequence_count = i.SequenceCount,
            attachment_count = i.AttachmentCount,
        }

        local mins, maxs = i.HullMin, i.HullMax
        if isvector(mins) and isvector(maxs) then
            out.bounds = {
                mins = mins,
                maxs = maxs,
                size = maxs - mins,
                center = (mins + maxs) * 0.5,
            }
        end

        if args.include_render_bounds == true then
            local rmin, rmax = measureRenderBounds(model)
            if rmin and rmax then
                out.render_bounds = {
                    mins = rmin,
                    maxs = rmax,
                    size = rmax - rmin,
                    center = (rmin + rmax) * 0.5,
                }
            end
        end

        local matNames, matTrunc = names(i.Materials, MATERIAL_CAP)
        out.materials = matNames
        if matTrunc then out.materials_truncated = true end

        local seqNames, seqTrunc = names(i.Sequences, SEQ_NAME_CAP)
        out.sequences = seqNames
        if seqTrunc then out.sequences_truncated = true end

        local attNames, attTrunc = names(i.Attachments, ATT_NAME_CAP)
        out.attachments = attNames
        if attTrunc then out.attachments_truncated = true end

        return out
    end,
})
