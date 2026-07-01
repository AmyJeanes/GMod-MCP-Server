-- world_trace: raycast from an arbitrary origin -- the generic sibling of player_trace
-- (which traces from a player's eyes). Replaces the hand-rolled util.TraceLine/TraceHull{
-- start=..., endpos=..., mask=..., filter=...} idiom (~50x in the corpus). Returns the same
-- hit block as player_trace (shared MCP.trace.HitBlock) plus the origin's point-contents and
-- the solid flags. A zero-length trace (no endpos/dir, or distance 0) is a PointContents
-- query at `start`. Both realms (_sv traces server collision, _cl client). Read-only/ungated.

local DEFAULT_DISTANCE = 16384 -- Source's canonical MAX_TRACE_LENGTH
local MAX_DISTANCE = 100000

local function parseVec3(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1] or t.x), tonumber(t[2] or t.y), tonumber(t[3] or t.z)
    if not (x and y and z) then return nil end
    return Vector(x, y, z)
end

-- Resolve a MASK_* constant name to its value; default MASK_SOLID (util.TraceLine's own).
local function resolveMask(name)
    if name == nil then return MASK_SOLID end
    if not isstring(name) or string.sub(name, 1, 5) ~= "MASK_" then
        return nil, "`mask` must be a MASK_* constant name (e.g. MASK_SOLID, MASK_SHOT, MASK_PLAYERSOLID)"
    end
    local v = _G[name]
    if not isnumber(v) then return nil, "unknown mask '" .. name .. "'" end
    return v
end

-- filter is a list of entindices to ignore (or a single index). Dead/invalid indices are
-- dropped so a stale entindex doesn't error the trace.
---@return Entity[]?
local function resolveFilter(f)
    if f == nil then return nil end
    if isnumber(f) then f = { f } end
    if not istable(f) then return nil end
    local ents = {}
    for _, idx in ipairs(f) do
        local e = Entity(tonumber(idx) or -1)
        if IsValid(e) then ents[#ents + 1] = e end
    end
    if #ents == 0 then return nil end
    return ents
end

MCP:AddFunction({
    id = "world_trace",
    description = "Raycast from an arbitrary origin and report what the ray hits -- the hit entity (index and class; drill in with entity_state), hit position, distance, surface normal and material, plus the origin's point-contents and the trace's solid flags. The generic sibling of player_trace (which traces from a player's eyes). Give `start`, then either `endpos` (an explicit end point) or `dir` + `distance` (a direction, normalised, times a length; default 16384). With neither, or distance 0, it's a zero-length PointContents query at `start` (start_contents/start_solid, no hit geometry). Supply `mins`+`maxs` for a swept-hull trace (util.TraceHull) instead of a line; `mask` picks the collision mask (a MASK_* name, default MASK_SOLID); `filter` is a list of entindices to ignore. start_contents decodes util.PointContents at the origin to CONTENTS_* names; start_solid/all_solid flag an origin embedded in solid. Both realms (_sv traces server collision, _cl client). Read-only.",
    schema = {
        type = "object",
        properties = {
            start = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Ray origin [x,y,z] (required).",
            },
            endpos = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Explicit end point [x,y,z]. Takes precedence over dir/distance.",
            },
            dir = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Ray direction [x,y,z] (normalised internally); the end point is start + dir*distance. Ignored if `endpos` is given.",
            },
            distance = {
                type = "number", minimum = 0, maximum = MAX_DISTANCE,
                description = "Ray length for the `dir` form (default 16384). 0 = a PointContents query at `start`.",
            },
            mins = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Hull mins [x,y,z]; supply with `maxs` for a swept-hull trace (util.TraceHull) instead of a line.",
            },
            maxs = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Hull maxs [x,y,z]; supply with `mins`.",
            },
            mask = {
                type = "string",
                description = "Collision mask as a MASK_* constant name (default MASK_SOLID). e.g. MASK_SHOT, MASK_PLAYERSOLID, MASK_WATER.",
            },
            filter = {
                type = "array", items = { type = "integer" },
                description = "Entity indices to ignore (the ray passes through them).",
            },
        },
        required = { "start" },
    },
    handler = function(args)
        args = args or {}

        local start = parseVec3(args.start)
        if not start then return { ok = false, error = "`start` must be a [x,y,z] position" } end

        local endpos
        if args.endpos ~= nil then
            endpos = parseVec3(args.endpos)
            if not endpos then return { ok = false, error = "`endpos` must be a [x,y,z] position" } end
        elseif args.dir ~= nil then
            local dir = parseVec3(args.dir)
            if not dir then return { ok = false, error = "`dir` must be a [x,y,z] direction" } end
            local dist = math.Clamp(tonumber(args.distance) or DEFAULT_DISTANCE, 0, MAX_DISTANCE)
            endpos = start + dir:GetNormalized() * dist
        else
            -- No direction given: a point query at `start`.
            endpos = start
        end

        local mins, maxs
        if args.mins ~= nil or args.maxs ~= nil then
            mins, maxs = parseVec3(args.mins), parseVec3(args.maxs)
            if not (mins and maxs) then
                return { ok = false, error = "a hull trace needs both `mins` and `maxs` as [x,y,z]" }
            end
        end

        local mask, maskErr = resolveMask(args.mask)
        if maskErr then return { ok = false, error = maskErr } end

        local td = {
            start = start,
            endpos = endpos,
            mask = mask,
            filter = resolveFilter(args.filter),
        }
        if mins then td.mins, td.maxs = mins, maxs end
        -- The glua-api stub mistypes the trace `filter` field as table<Entity> (an
        -- Entity-keyed map) when the API takes a sequential Entity[]; our list is correct.
        ---@diagnostic disable-next-line: param-type-mismatch
        local tr = mins and util.TraceHull(td) or util.TraceLine(td)

        local r = MCP.trace.HitBlock(tr, start)
        r.ok = true
        r.realm = MCP.util.RealmName()
        r.end_pos = endpos
        if mins then r.hull = { mins = mins, maxs = maxs } end

        local contents = util.PointContents(start)
        r.start_contents_raw = contents
        r.start_contents = MCP.util.DecodeBits("CONTENTS_", contents)
        r.start_solid = tr.StartSolid == true
        r.all_solid = tr.AllSolid == true

        if start:DistToSqr(endpos) == 0 then r.point_contents_only = true end

        return r
    end,
})
