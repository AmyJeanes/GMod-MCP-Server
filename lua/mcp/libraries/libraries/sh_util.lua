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
