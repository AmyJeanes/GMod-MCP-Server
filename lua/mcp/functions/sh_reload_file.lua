-- reload_file: hot-reload one on-disk Lua source file by re-running it (include) in this
-- realm. A targeted alternative to mcp_reload (which rebuilds the whole MCP addon + manifest)
-- and the engine's autorefresh (which only fires for some edits) -- for iterating on a single
-- file in ANY addon, not just this one.
--
-- Ungated: include resolves only within the game's Lua search paths (no arbitrary-filesystem
-- reach) and runs no caller-supplied code -- it only re-executes a file the game already has
-- installed, so it adds no capability beyond what the game runs at load. Run a file in its own
-- realm: a sv_ file via _sv, a cl_ file via _cl, a sh_ file via both. The file is re-executed,
-- so it must be idempotent (unique hook IDs, MCP:AddFunction is, etc.) -- the same contract
-- autorefresh relies on.

-- Reject traversal / absolute paths defensively (include is already sandboxed to search paths).
local function badPath(p)
    return p:find("%.%.") ~= nil or p:find("^[/\\]") ~= nil
end

MCP:AddFunction({
    id = "reload_file",
    description = "Hot-reload one on-disk Lua source file by re-running it in this realm -- a targeted alternative to mcp_reload (which rebuilds the whole MCP addon) and the engine's autorefresh (which only fires for some edits), for iterating on a single file in any addon. `path` is relative to a lua/ search root (the same path include() takes), e.g. \"autorun/server/myfile.lua\" or \"tardis/core/sh_thing.lua\". The file is re-executed via include(), so it must be idempotent (unique hook IDs etc.) -- the same contract autorefresh relies on. Ungated: it only re-runs code already installed in the LUA search path (no arbitrary-filesystem reach, no caller-supplied code). Run a file in its own realm -- a sv_ file via _sv, a cl_ file via _cl, a sh_ file via both realms. Returns ok/path and any values the file returned. (On a listen-server host the client realm's file view is the boot-time snapshot, so reloading a clientside file there is best-effort: a file added or edited since boot may be invisible (not found) or re-run a stale copy. The server realm always reads fresh from disk. For clientside iteration prefer autorefresh or a relaunch.) Runs in both realms.",
    schema = {
        type = "object",
        properties = {
            path = {
                type = "string",
                description = "Lua file path relative to a lua/ search root (the path include() takes), e.g. \"autorun/server/myfile.lua\" or \"tardis/core/sh_thing.lua\". Must exist in the LUA search path.",
            },
        },
        required = { "path" },
    },
    handler = function(args)
        args = args or {}
        local path = args.path
        if type(path) ~= "string" or path == "" then
            return { ok = false, error = "`path` must be a non-empty Lua file path" }
        end
        if badPath(path) then
            return { ok = false, error = "`path` must be a relative path inside the lua/ search root (no .. or leading slash)" }
        end
        if not file.Exists(path, "LUA") then
            return { ok = false, error = "no Lua file '" .. path .. "' in the LUA search path (path is relative to lua/)" }
        end

        local res = { pcall(include, path) }
        local ok = table.remove(res, 1)
        if not ok then
            return { ok = false, realm = MCP.util.RealmName(), path = path, error = "reload error: " .. tostring(res[1]) }
        end

        local out = {
            ok = true,
            realm = MCP.util.RealmName(),
            path = path,
            reloaded = true,
        }
        -- Surface any values the file returned (some modules return a table), like lua_run.
        if #res > 0 then
            out.returns = #res
            out.result = (#res == 1) and MCP.util.Serialize(res[1]) or MCP.util.Serialize(res)
        end
        return out
    end,
})
