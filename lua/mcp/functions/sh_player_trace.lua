-- player_trace: raycast from a player's eyes along their view -- "what am I looking at."
-- Returns the hit entity (index/class -- drill in with entity_state), hit position,
-- distance, surface normal and material (shared MCP.trace.HitBlock, same shape world_trace
-- returns). Replaces the hand-rolled util.TraceLine{start=EyePos(), endpos=EyePos()+aim*N,
-- filter=ply} idiom. Subject selector like player_state (host/bot/name/userid/entindex/all;
-- no selector = host). Both realms (_sv traces server collision, _cl client). Ungated.
-- For an arbitrary origin (not a player's eyes), use world_trace.

local TRACE_DISTANCE = 16384 -- default ray length: Source's canonical MAX_TRACE_LENGTH
local MAX_DISTANCE = 100000

local function parseVec3(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1] or t.x), tonumber(t[2] or t.y), tonumber(t[3] or t.z)
    if not (x and y and z) then return nil end
    return Vector(x, y, z)
end

-- Trace from `ply` along its eye angles. opts: distance, origin (start override, default
-- EyePos), mins/maxs (swept-hull instead of a line).
local function traceFrom(ply, opts)
    local ang = ply:EyeAngles()
    local start = opts.origin or ply:EyePos()

    local td = {
        start = start,
        endpos = start + ang:Forward() * opts.distance,
        filter = ply,
    }
    if opts.mins then td.mins, td.maxs = opts.mins, opts.maxs end
    local tr = opts.mins and util.TraceHull(td) or util.TraceLine(td)

    local r = MCP.trace.HitBlock(tr, start)
    r.subject = MCP.player.Identity(ply)
    r.aim_angles = ang
    if opts.mins then r.hull = { mins = opts.mins, maxs = opts.maxs } end
    return r
end

MCP:AddFunction({
    id = "player_trace",
    description = "Raycast from a player's eyes along their view and report what they're looking at -- the hit entity (index and class; drill in with entity_state), hit position, distance from the eye, surface normal, and surface material/texture. The trace filters out the subject itself and uses a standard solid mask. Subject is exactly one of `host` (the listen/SP host), `bot`, `name`, `userid`, or `entindex` -- or `all` to trace from every player (returns a `traces` array). With no selector it defaults to the host. `distance` sets the ray length (default 16384). Supply `origin` to trace from a point other than the eyes (still along the player's view direction), and `mins`+`maxs` for a swept-hull trace instead of a line. When nothing is hit within range, hit=false and the entity field is omitted; hit_world=true means the ray hit the map (no entity). For an arbitrary origin and direction, use world_trace instead. Runs in both realms (_sv traces server collision, _cl client). Read-only.",
    schema = {
        type = "object",
        properties = {
            host = {
                type = "boolean",
                description = "Trace from the listen/SP host player. Omit all selectors to default to the host.",
            },
            bot = {
                type = "boolean",
                description = "Trace from the only bot on the server (errors if there are zero or more than one).",
            },
            name = {
                type = "string",
                description = "Trace from the player whose name matches (exact first, else case-insensitive contains; ambiguous matches error).",
            },
            userid = {
                type = "integer",
                description = "Trace from the player with this UserID (Player:UserID()).",
            },
            entindex = {
                type = "integer",
                description = "Trace from the player at this entity index.",
            },
            all = {
                type = "boolean",
                description = "Trace from every player instead of one; returns a `traces` array. Mutually exclusive with the other selectors.",
            },
            distance = {
                type = "number", minimum = 1, maximum = MAX_DISTANCE,
                description = "Ray length in units (default 16384). The engine clamps very long traces to its max length.",
            },
            origin = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Start the ray at this [x,y,z] instead of the player's eye position (direction is still the player's view).",
            },
            mins = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Hull mins [x,y,z]; supply with `maxs` for a swept-hull trace (util.TraceHull) instead of a line.",
            },
            maxs = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Hull maxs [x,y,z]; supply with `mins`.",
            },
        },
    },
    ---@param args table
    handler = function(args)
        args = args or {}

        local dist = math.Clamp(tonumber(args.distance) or TRACE_DISTANCE, 1, MAX_DISTANCE)

        local origin
        if args.origin ~= nil then
            origin = parseVec3(args.origin)
            if not origin then return { ok = false, error = "`origin` must be a [x,y,z] position" } end
        end

        local mins, maxs
        if args.mins ~= nil or args.maxs ~= nil then
            mins, maxs = parseVec3(args.mins), parseVec3(args.maxs)
            if not (mins and maxs) then
                return { ok = false, error = "a hull trace needs both `mins` and `maxs` as [x,y,z]" }
            end
        end

        local opts = { distance = dist, origin = origin, mins = mins, maxs = maxs }

        local list, err = MCP.player.Resolve(args, { default_host = true })
        if not list then return { ok = false, error = err } end

        if args.all then
            local out = {}
            for _, p in ipairs(list) do
                if IsValid(p) then out[#out + 1] = traceFrom(p, opts) end
            end
            return { ok = true, realm = MCP.util.RealmName(), count = #out, traces = out }
        end

        local r = traceFrom(list[1], opts)
        r.ok = true
        r.realm = MCP.util.RealmName()
        return r
    end,
})
