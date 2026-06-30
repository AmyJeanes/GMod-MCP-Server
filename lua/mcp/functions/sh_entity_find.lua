-- entity_find: locate many entities and return compact rows. The locate-half of
-- the entity family (entity_state inspects one by index, entity_set mutates).
-- Replaces the recurring ents.FindBy*/FindInSphere/FindInBox loops that hand-format
-- a row per match -- and the raw class scan that once returned 237K chars and blew
-- the token budget. Server-side cap + field projection + nearest-first sort are the
-- DEFAULT so a broad query degrades to "the closest N", not a dump. Both realms:
-- the client realm only sees entities in its PVS (dormant/parked ones won't appear).
-- Ungated (structured read).

-- Accept a 3-vector as either [x,y,z] (JSON array) or {x=,y=,z=}.
local function vec3(t)
    if type(t) ~= "table" then return nil end
    local x = tonumber(t[1] or t.x)
    local y = tonumber(t[2] or t.y)
    local z = tonumber(t[3] or t.z)
    if not (x and y and z) then return nil end
    return Vector(x, y, z)
end

-- Class matcher honouring the same `*` wildcard ents.FindByClass accepts.
local function classMatcher(pat)
    if not pat then return nil end
    if not string.find(pat, "*", 1, true) then
        return function(c) return c == pat end
    end
    -- escape every Lua-pattern magic char EXCEPT '*', then turn '*' into '.*'
    local p = string.gsub(pat, "[%^%$%(%)%.%[%]%+%-%?%%]", "%%%0")
    p = "^" .. string.gsub(p, "%*", ".*") .. "$"
    return function(c) return string.match(c, p) ~= nil end
end

-- The listen/SP host: LocalPlayer on the client, the IsListenServerHost player on
-- the server. Used as the default sort centre so a plain scan returns nearest-to-you.
local function hostPlayer()
    if CLIENT then
        local lp = LocalPlayer()
        return IsValid(lp) and lp or nil
    end
    for _, p in ipairs(player.GetAll()) do
        if p:IsListenServerHost() then return p end
    end
    return nil
end

MCP:AddFunction({
    id = "entity_find",
    description = "Find entities and return compact rows -- index, class, model, pos and distance -- instead of a raw dump. Filter by class (wildcard ok, e.g. prop_*), model substring, a sphere (radius around an entity/point), an axis-aligned box, or all entities; filters combine (AND). Results are sorted nearest-first (to the given centre, or the host player when none is given) and capped (default 25, max 200), with total_matched and capped reported -- so a broad query can't blow the token budget. Drill into any returned index with entity_state. Realm-aware: the client realm only sees entities currently in its PVS (dormant or parked entities won't appear), so _sv and _cl results can differ. Runs in both realms.",
    schema = {
        type = "object",
        properties = {
            class = {
                type = "string",
                description = "Class to match; supports a `*` wildcard (e.g. \"prop_*\", \"*_door\"). Used as the engine lookup when it is the only selector, otherwise a filter.",
            },
            model = {
                type = "string",
                description = "Case-insensitive substring of the model path (e.g. \"wood_crate\").",
            },
            around = {
                type = "integer",
                description = "Entity index to centre the search/sort on (uses that entity's position).",
            },
            point = {
                type = "array",
                items = { type = "number" },
                minItems = 3, maxItems = 3,
                description = "Explicit centre point [x,y,z] (alternative to `around`).",
            },
            radius = {
                type = "number",
                description = "With a centre (`around`/`point`, or the host player), restrict matches to this sphere. Required to do a sphere search.",
            },
            box = {
                type = "object",
                description = "Axis-aligned world box to search within.",
                properties = {
                    mins = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3 },
                    maxs = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3 },
                },
            },
            all = {
                type = "boolean",
                description = "Match every entity (still capped). Use when you have no narrower filter.",
            },
            limit = {
                type = "integer", minimum = 1, maximum = 200,
                description = "Max rows to return (default 25, max 200). Results are nearest-first, so the cap keeps the closest.",
            },
        },
    },
    handler = function(args)
        args = args or {}

        local hasClass = type(args.class) == "string" and args.class ~= ""
        local hasModel = type(args.model) == "string" and args.model ~= ""
        local radius = tonumber(args.radius)
        local box = type(args.box) == "table" and args.box or nil
        local wantAll = args.all == true

        if not (hasClass or hasModel or radius or box or wantAll) then
            return { ok = false, error = "specify at least one of: class, model, radius (with around/point), box, all" }
        end

        -- Resolve an explicit centre from around/point (used for both the sphere and the sort).
        local center, centerSource
        if args.around ~= nil then
            local e = Entity(tonumber(args.around) or -1)
            if not IsValid(e) then
                return { ok = false, error = "`around`: entity " .. tostring(args.around) .. " is not valid" }
            end
            center, centerSource = e:GetPos(), "around"
        elseif args.point ~= nil then
            local v = vec3(args.point)
            if not v then return { ok = false, error = "`point` must be [x,y,z]" } end
            center, centerSource = v, "point"
        end

        -- Pick the cheapest engine base-set, then filter it. Priority: box > sphere >
        -- class index > everything.
        local baseSet
        if box then
            local mn, mx = vec3(box.mins), vec3(box.maxs)
            if not mn or not mx then return { ok = false, error = "`box` needs mins and maxs as [x,y,z]" } end
            baseSet = ents.FindInBox(mn, mx)
            if not center then center, centerSource = (mn + mx) / 2, "box" end
        elseif radius then
            if not center then
                local h = hostPlayer()
                if not IsValid(h) then
                    return { ok = false, error = "`radius` needs a centre: pass around/point, or have a listen host" }
                end
                center, centerSource = h:GetPos(), "host"
            end
            baseSet = ents.FindInSphere(center, radius)
        elseif hasClass then
            baseSet = ents.FindByClass(args.class)
        else
            baseSet = ents.GetAll()
        end

        -- Default the sort centre to the host player when nothing spatial was given.
        if not center then
            local h = hostPlayer()
            if IsValid(h) then center, centerSource = h:GetPos(), "host" end
        end

        local classMatch = hasClass and classMatcher(args.class) or nil
        local modelLower = hasModel and string.lower(args.model) or nil

        local rows = {}
        for _, e in ipairs(baseSet) do
            if IsValid(e) then
                local cls = e:GetClass()
                if not classMatch or classMatch(cls) then
                    local mdl = e:GetModel()
                    if not modelLower or (mdl and string.find(string.lower(mdl), modelLower, 1, true)) then
                        local pos = e:GetPos()
                        local row = { index = e:EntIndex(), class = cls, model = mdl, pos = pos }
                        if center then row.distance = math.Round(pos:Distance(center), 1) end
                        rows[#rows + 1] = row
                    end
                end
            end
        end

        local total = #rows
        if center then
            table.sort(rows, function(a, b) return (a.distance or 0) < (b.distance or 0) end)
        end

        local limit = math.Clamp(math.floor(tonumber(args.limit) or 25), 1, 200)
        local results = {}
        for i = 1, math.min(limit, total) do results[i] = rows[i] end

        return {
            ok = true,
            realm = MCP.util.RealmName(),
            total_matched = total,
            returned = #results,
            capped = total > #results,
            center = center,
            center_source = centerSource,
            results = results,
        }
    end,
})
