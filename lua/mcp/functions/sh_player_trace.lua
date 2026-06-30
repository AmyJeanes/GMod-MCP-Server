-- player_trace: raycast from a player's eyes along their view -- "what am I looking at."
-- Returns the hit entity (index/class -- drill in with entity_state), hit position,
-- distance, surface normal and material. Replaces the hand-rolled
-- util.TraceLine{start=EyePos(), endpos=EyePos()+aim*N, filter=ply} idiom. Subject selector
-- like player_state (host/bot/name/userid/entindex/all; no selector = host). Both realms
-- (_sv traces server collision, _cl client). Read-only/ungated.

local TRACE_DISTANCE = 16384 -- default ray length: Source's canonical MAX_TRACE_LENGTH
local MAX_DISTANCE = 100000

-- tr.MatType is a byte; MCP.util.DecodeEnum("MAT_", ...) maps it to its MAT_* constant name
-- ("MAT_" excludes the "MATERIAL_" prefix -- 4th char differs).

local function traceFrom(ply, dist)
    local eye = ply:EyePos()
    local ang = ply:EyeAngles()
    local tr = util.TraceLine({
        start = eye,
        endpos = eye + ang:Forward() * dist,
        filter = ply,
    })

    local r = {
        subject = MCP.player.Identity(ply),
        start_pos = eye,
        aim_angles = ang,
        hit = tr.Hit == true,
        hit_world = tr.HitWorld == true,
        hit_sky = tr.HitSky == true,
        fraction = math.Round(tr.Fraction, 4),
        distance = math.Round(eye:Distance(tr.HitPos), 1),
        hit_pos = tr.HitPos,
        hit_normal = tr.HitNormal,
    }

    local ent = tr.Entity
    if IsValid(ent) then
        local e = {
            index = ent:EntIndex(),
            class = ent:GetClass(),
            is_player = ent:IsPlayer(),
            is_npc = ent:IsNPC(),
        }
        local nm = ent:IsPlayer() and ent:Nick() or ent:GetName()
        if nm and nm ~= "" then e.name = nm end
        r.entity = e
    end

    if isstring(tr.HitTexture) and tr.HitTexture ~= "" then r.surface = tr.HitTexture end
    if isnumber(tr.MatType) then r.material_type = MCP.util.DecodeEnum("MAT_", tr.MatType) end

    return r
end

MCP:AddFunction({
    id = "player_trace",
    description = "Raycast from a player's eyes along their view and report what they're looking at -- the hit entity (index and class; drill in with entity_state), hit position, distance from the eye, surface normal, and surface material/texture. The trace filters out the subject itself and uses a standard solid mask. Subject is exactly one of `host` (the listen/SP host), `bot`, `name`, `userid`, or `entindex` -- or `all` to trace from every player (returns a `traces` array). With no selector it defaults to the host. `distance` sets the ray length (default 16384). When nothing is hit within range, hit=false and the entity field is omitted; hit_world=true means the ray hit the map (no entity). Runs in both realms (_sv traces server collision, _cl client). Read-only.",
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
        },
    },
    handler = function(args)
        args = args or {}

        local dist = math.Clamp(tonumber(args.distance) or TRACE_DISTANCE, 1, MAX_DISTANCE)

        local list, err = MCP.player.Resolve(args, { default_host = true })
        if not list then return { ok = false, error = err } end

        if args.all then
            local out = {}
            for _, p in ipairs(list) do
                if IsValid(p) then out[#out + 1] = traceFrom(p, dist) end
            end
            return { ok = true, realm = MCP.util.RealmName(), count = #out, traces = out }
        end

        local r = traceFrom(list[1], dist)
        r.ok = true
        r.realm = MCP.util.RealmName()
        return r
    end,
})
