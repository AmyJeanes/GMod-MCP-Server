-- file_exists: does a path exist in the GMod VFS, and is it a file or dir + its size/time.
-- file.Exists / file.IsDir / file.Size / file.Time. The direct asset-validation check;
-- companion to file_find (the glob/list tool).

MCP:AddFunction({
    id = "file_exists",
    description = "Check whether a single path exists in the GMod virtual filesystem, and report whether it's a file or folder plus its size and modified time -- file.Exists/IsDir/Size/Time. The direct asset-validation check (\"is this model/material/map present?\") without a glob. `path` is the exact path, e.g. \"models/props_c17/oildrum001.mdl\". `search_path` is the search-path id (default \"GAME\" = all mounted content; also DATA, LUA, MOD, DOWNLOAD, WORKSHOP). Returns `exists`, `is_dir`, and for a file `size_bytes` plus `modified_unix`/`modified` (formatted, when the mount reports a time -- files packed in VPK/GMA often report 0, then it's omitted). Server and client realms can differ in mounted content. Complement of file_find.",
    schema = {
        type = "object",
        properties = {
            path = { type = "string", description = "Exact path to check, e.g. \"models/props_c17/oildrum001.mdl\"." },
            search_path = { type = "string", description = "Search-path id: GAME (default), DATA, LUA, MOD, DOWNLOAD, WORKSHOP." },
        },
        required = { "path" },
    },
    handler = function(args)
        args = args or {}
        if type(args.path) ~= "string" or args.path == "" then
            return { ok = false, error = "`path` must be a non-empty path (e.g. \"models/props_c17/oildrum001.mdl\")" }
        end
        local sp = args.search_path
        if sp ~= nil and type(sp) ~= "string" then return { ok = false, error = "`search_path` must be a search-path id string (e.g. \"GAME\", \"DATA\")" } end
        sp = sp or "GAME"

        local exists = file.Exists(args.path, sp)
        local isDir = file.IsDir(args.path, sp)
        local result = {
            ok = true,
            realm = MCP.util.RealmName(),
            path = args.path,
            search_path = sp,
            exists = exists,
            is_dir = isDir,
        }
        if exists and not isDir then
            local size = file.Size(args.path, sp)
            if size and size >= 0 then result.size_bytes = size end
            local t = file.Time(args.path, sp)
            if t and t > 0 then
                result.modified_unix = t
                result.modified = os.date("%Y-%m-%d %H:%M:%S", t)
            end
        end
        return result
    end,
})
