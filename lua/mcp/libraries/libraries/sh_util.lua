MCP.util = MCP.util or {}

function MCP.util.RealmName()
    return SERVER and "server" or "client"
end

function MCP.util.JsonEncode(t, pretty)
    return util.TableToJSON(t, pretty == true)
end

function MCP.util.JsonDecode(s)
    if s == nil or s == "" then return nil end
    return util.JSONToTable(s)
end

-- Convert an arbitrary Lua value into a JSON-safe structure for the response
-- path. GMod types util.TableToJSON can't represent become readable objects,
-- functions / other userdata become tagged strings, and cycles, over-depth and
-- runaway size are capped so a tool return (or a raw `lua_run` value) can never
-- crash the encoder or blow the token budget. Verbose by design — this is read
-- by a human/LLM, not a save format (cf. vON, which optimises for compactness
-- and simply errors on types it doesn't know).
local SERIALIZE_MAX_DEPTH = 12
local SERIALIZE_MAX_NODES = 4000

local function serializeValue(v, seen, state, depth)
    if v == nil then return nil end

    if isnumber(v) then
        -- JSON has no NaN/Infinity; emitting them produces invalid JSON the
        -- .NET host can't parse, so describe them instead.
        if v ~= v then return "<nan>" end
        if v == math.huge then return "<inf>" end
        if v == -math.huge then return "<-inf>" end
        return v
    end
    if isstring(v) or isbool(v) then return v end

    if isvector(v) then return { x = v.x, y = v.y, z = v.z } end
    if isangle(v) then return { p = v.p, y = v.y, r = v.r } end
    if IsColor(v) then return { r = v.r, g = v.g, b = v.b, a = v.a } end

    if isentity(v) then
        -- A NULL/removed entity errors on any method call, so probe GetClass
        -- under pcall. This also correctly reports the worldspawn, whose IsValid
        -- is false (a GMod quirk) yet which is a real, readable entity.
        local gotClass, class = pcall(v.GetClass, v)
        if not gotClass then return { valid = false, class = "[NULL]" } end
        local e = { valid = IsValid(v), class = class, index = v:EntIndex() }
        if v:IsPlayer() then e.name = v:Nick() end
        return e
    end

    if istable(v) then
        if depth > state.maxDepth then return "<truncated: too deep>" end
        if seen[v] then return "<cycle>" end
        seen[v] = true
        local out = {}
        for k, val in pairs(v) do
            state.nodes = state.nodes + 1
            if state.nodes > state.maxNodes then
                out.__truncated = "serialization size cap reached"
                break
            end
            -- JSON keys must be strings/numbers; coerce anything else (a table-
            -- or entity-keyed map) so the key isn't silently dropped.
            local key = (isstring(k) or isnumber(k)) and k or tostring(k)
            out[key] = serializeValue(val, seen, state, depth + 1)
        end
        seen[v] = nil
        return out
    end

    if isfunction(v) then return "<function>" end

    -- IMaterial, PhysObj, CSoundPatch, CNavArea, … — tostring is descriptive.
    return tostring(v)
end

-- opts (optional): { max_depth, max_nodes } override the defaults so a caller
-- embedding a potentially-huge sub-structure (e.g. entity_state's GetTable dump,
-- where a TARDIS .metadata def can be enormous) can cap it tighter than the
-- whole-response budget and never crowd out the rest of the response.
function MCP.util.Serialize(value, opts)
    opts = opts or {}
    local state = {
        nodes = 0,
        maxDepth = tonumber(opts.max_depth) or SERIALIZE_MAX_DEPTH,
        maxNodes = tonumber(opts.max_nodes) or SERIALIZE_MAX_NODES,
    }
    return serializeValue(value, {}, state, 1)
end

-- Feature-test + pcall a getter on `obj`: not every method exists on every object or in
-- every realm, and some return *nothing* (not nil). Returns a closure (method, ...) ->
-- value, or nil on absence/error/no-return so the caller just omits the field. The shared
-- read-tool primitive (entity_state, player_state, cvar_state) -- erases the
-- IsValid(e) and e:Foo() guard boilerplate that was the corpus's #1 error source.
function MCP.util.Getter(obj)
    return function(method, ...)
        local fn = obj[method]
        if not isfunction(fn) then return nil end
        local ok, res = pcall(fn, obj, ...)
        if not ok then return nil end
        return res
    end
end

-- Map every _G constant named "<prefix>*" that holds a number to {[value] = name}, so an
-- engine enum decodes to its readable constant ("MOVETYPE_NONE" not 11). Built lazily and
-- memoized per prefix -- NOT at file-load, so a tool's registration stays bare for the
-- headless tool-list generator (the scan touches _G/isnumber, in-game-only globals).
local enumCache = {}
function MCP.util.EnumMap(prefix)
    local cached = enumCache[prefix]
    if cached then return cached end
    local m = {}
    for k, v in pairs(_G) do
        if isnumber(v) and string.sub(k, 1, #prefix) == prefix then m[v] = k end
    end
    enumCache[prefix] = m
    return m
end

-- Decode an enum int to its "<prefix>*" constant name, falling back to the raw value for an
-- unknown one. nil passes through (an absent field stays absent).
function MCP.util.DecodeEnum(prefix, v)
    if v == nil then return nil end
    return MCP.util.EnumMap(prefix)[v] or v
end

-- Validates a request/response id is safe to use as a filename component.
-- Allows alphanumerics, underscore, hyphen, and period.
function MCP.util.IsSafeId(id)
    if type(id) ~= "string" or id == "" then return false end
    return id:find("[^a-zA-Z0-9._%-]") == nil
end

-- True if a map .bsp is present in mounted GAME content (base game + mounted
-- workshop addons). Accepts a name with or without the .bsp suffix; rejects
-- path separators and ".." so a caller-supplied name can't escape maps/.
function MCP.util.MapExists(map)
    if type(map) ~= "string" or map == "" then return false end
    map = map:gsub("%.bsp$", "")
    if map:find("[/\\]") or map:find("%.%.") then return false end
    return file.Exists("maps/" .. map .. ".bsp", "GAME")
end
