-- MCP.trace: the shared hit-block serialization for the trace tools. player_trace
-- (eye-based) and world_trace (arbitrary origin) both produce the same "what did the
-- ray hit" structure -- the hit entity (index/class -- drill in with entity_state),
-- hit position, distance, surface normal, and material -- so it lives here once.
--
-- Both realms; the headless tool-list generator does not load this file (its framework
-- list is fixed), which is fine because tools call MCP.trace.* only inside handlers.

MCP.trace = MCP.trace or {}

-- Build the common hit block from a util.TraceLine/TraceHull result. `start_pos` is the
-- ray origin, so distance is measured from it. Each tool adds its own extras on top
-- (player_trace: subject/aim_angles; world_trace: end_pos/start_contents/solid flags).
---@param tr TraceResult
---@param start_pos Vector
function MCP.trace.HitBlock(tr, start_pos)
    local r = {
        start_pos = start_pos,
        hit = tr.Hit == true,
        hit_world = tr.HitWorld == true,
        hit_sky = tr.HitSky == true,
        fraction = math.Round(tr.Fraction, 4),
        hit_pos = tr.HitPos,
        hit_normal = tr.HitNormal,
    }
    if isvector(start_pos) and isvector(tr.HitPos) then
        r.distance = math.Round(start_pos:Distance(tr.HitPos), 1)
    end

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
    -- tr.MatType is a byte; "MAT_" (not "MATERIAL_" -- 4th char differs) is the constant set.
    if isnumber(tr.MatType) then r.material_type = MCP.util.DecodeEnum("MAT_", tr.MatType) end

    return r
end
