-- file_find: enumerate the GMod virtual filesystem -- file.Find(pattern, path). Asset
-- validation / "what's in this folder" without hand-rolling file.Find + a table dump.

local DEFAULT_LIMIT = 200
local MAX_LIMIT = 1000
local VALID_SORT = { nameasc = true, namedesc = true, dateasc = true, datedesc = true }

---@param list string[]
---@param limit number
local function cap(list, limit)
    local n = #list
    if n <= limit then return list, false end
    local out = {}
    for i = 1, limit do out[i] = list[i] end
    return out, true
end

MCP:AddFunction({
    id = "file_find",
    description = "List files and folders in the GMod virtual filesystem matching a glob -- file.Find(pattern, path). Use for asset validation or browsing mounted content without hand-rolling file.Find. `pattern` is a path glob, e.g. \"models/props_c17/*.mdl\" or \"maps/*\" (a trailing \"/*\" lists a whole folder). `path` is the search-path id (default \"GAME\" = all mounted game+addon content; others: \"DATA\" the garrysmod/data dir, \"LUA\", \"MOD\", \"DOWNLOAD\", \"WORKSHOP\"). Returns `files` and `folders` (names only, not full paths -- prepend the pattern's directory), each capped by `limit` (default 200, max 1000) with a *_truncated flag and the true *_count. Empty lists for no match (never an error). Server and client realms can differ in mounted content -- pick the realm you care about.",
    schema = {
        type = "object",
        properties = {
            pattern = { type = "string", description = "Path glob, e.g. \"models/props_c17/*.mdl\" or \"maps/*\" (a folder's contents). Relative to the search path." },
            path = { type = "string", description = "Search-path id: GAME (default, all mounted content), DATA, LUA, MOD, DOWNLOAD, WORKSHOP." },
            sort = { type = "string", description = "Optional file.Find sort: nameasc (default), namedesc, dateasc, datedesc." },
            limit = { type = "integer", minimum = 1, maximum = MAX_LIMIT, description = "Max entries per list (default 200)." },
        },
        required = { "pattern" },
    },
    handler = function(args)
        args = args or {}
        if type(args.pattern) ~= "string" or args.pattern == "" then
            return { ok = false, error = "`pattern` must be a non-empty path glob (e.g. \"models/props_c17/*.mdl\")" }
        end
        local path = args.path
        if path ~= nil and type(path) ~= "string" then return { ok = false, error = "`path` must be a search-path id string (e.g. \"GAME\", \"DATA\")" } end
        path = path or "GAME"
        local sort = args.sort
        if sort ~= nil then
            if type(sort) ~= "string" or not VALID_SORT[sort] then
                return { ok = false, error = "`sort` must be one of: nameasc, namedesc, dateasc, datedesc" }
            end
        end
        local limit = math.Clamp(math.floor(tonumber(args.limit) or DEFAULT_LIMIT), 1, MAX_LIMIT)

        local files, folders = file.Find(args.pattern, path, sort)
        files = files or {}
        folders = folders or {}
        local fileCount, folderCount = #files, #folders
        local capFiles, filesTrunc = cap(files, limit)
        local capFolders, foldersTrunc = cap(folders, limit)

        return {
            ok = true,
            realm = MCP.util.RealmName(),
            pattern = args.pattern,
            path = path,
            files = capFiles,
            folders = capFolders,
            file_count = fileCount,
            folder_count = folderCount,
            files_truncated = filesTrunc,
            folders_truncated = foldersTrunc,
        }
    end,
})
