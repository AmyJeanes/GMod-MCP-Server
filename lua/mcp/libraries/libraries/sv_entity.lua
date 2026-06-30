-- Shared server-side entity-mutation primitives for the entity_* write tools
-- (entity_create spawns, entity_set mutates). Server realm -- prop physics/render
-- mutation is server-authoritative. These are the de-duplicated incantations the scan
-- flagged as most-repeated (the GetPhysicsObject + IsValid + EnableMotion triad recurred
-- 7x in TARDIS alone), so every entity write tool behaves identically from one home.
--
-- The headless tool-list generator does not load this file (its framework list is fixed),
-- which is fine: tools call MCP.entity.* only inside handlers, never at file-load, so the
-- generator (registration-only, never runs handlers) never needs it.

MCP.entity = MCP.entity or {}

-- Parse [r,g,b] or [r,g,b,a] (each 0-255, clamped) into a Color. nil + reason if malformed.
function MCP.entity.ParseColor(t)
    if type(t) ~= "table" then return nil, "must be [r,g,b] or [r,g,b,a]" end
    local r, g, b = tonumber(t[1] or t.r), tonumber(t[2] or t.g), tonumber(t[3] or t.b)
    local a = tonumber(t[4] or t.a) or 255
    if not (r and g and b) then return nil, "must be [r,g,b] or [r,g,b,a]" end
    local function clamp(n) return math.Clamp(math.floor(n), 0, 255) end
    return Color(clamp(r), clamp(g), clamp(b), clamp(a))
end

-- Apply a colour, switching to a render mode that respects alpha when it's < 255
-- (otherwise a translucent colour draws fully opaque).
function MCP.entity.ApplyColor(ent, col)
    ent:SetColor(col)
    ent:SetRenderMode(col.a < 255 and RENDERMODE_TRANSALPHA or RENDERMODE_NORMAL)
end

-- The freeze triad: GetPhysicsObject + IsValid + EnableMotion. frozen=true disables
-- motion and sleeps; false enables and wakes. Returns whether a valid physics object was
-- present to act on, so callers report the real state rather than the requested one.
function MCP.entity.SetFrozen(ent, frozen)
    local phys = ent:GetPhysicsObject()
    if not IsValid(phys) then return false end
    phys:EnableMotion(not frozen)
    if frozen then phys:Sleep() else phys:Wake() end
    return true
end
