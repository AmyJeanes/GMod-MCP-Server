-- reload_file: hot-reload one on-disk Lua source file by re-running it (include) in this
-- realm. A targeted alternative to mcp_reload (which rebuilds the whole MCP addon + manifest)
-- and the engine's autorefresh (which only fires for some edits) -- for iterating on a single
-- file in ANY addon, not just this one.
--
-- Ungated: include/CompileString resolve only within the game's Lua search paths (no
-- arbitrary-filesystem reach) and run no caller-supplied code -- they only re-execute a file
-- the game already has installed, so it adds no capability beyond what the game runs at load.
-- Run a file in its own realm: a sv_ file via _sv, a cl_ file via _cl, a sh_ file via both.
-- The file is re-executed, so it must be idempotent (unique hook IDs, MCP:AddFunction is,
-- etc.) -- the same contract autorefresh relies on.

-- Reject traversal / absolute paths defensively (include is already sandboxed to search paths).
local function badPath(p)
    return p:find("%.%.") ~= nil or p:find("^[/\\]") ~= nil
end

-- Run the file, returning (ok, ...) like pcall. force_compile reads the source fresh and
-- CompileStrings it instead of include()ing -- this bypasses include's compiled-chunk cache,
-- which on a listen-server host client can serve a stale chunk for an edited file even though
-- the bytes on disk are current.
local function runFile(path, forceCompile)
    if not forceCompile then
        return pcall(include, path)
    end
    local src = file.Read(path, "LUA")
    if not isstring(src) then
        return false, "could not read '" .. path .. "' from disk for force_compile"
    end
    local chunk = CompileString(src, path, false) -- false: return the error string, don't throw
    if isstring(chunk) then
        return false, "compile error: " .. chunk
    end
    if not isfunction(chunk) then
        return false, "could not compile '" .. path .. "'"
    end
    return pcall(chunk)
end

MCP:AddFunction({
    id = "reload_file",
    description = "Hot-reload one on-disk Lua source file by re-running it in this realm -- a targeted alternative to mcp_reload (which rebuilds the whole MCP addon) and the engine's autorefresh (which only fires for some edits), for iterating on a single file in any addon. `path` is relative to a lua/ search root (the same path include() takes), e.g. \"autorun/server/myfile.lua\" or \"tardis/core/sh_thing.lua\". The file is re-executed, so it must be idempotent (unique hook IDs etc.) -- the same contract autorefresh relies on. `ent_class`: set this to a scripted-entity class name to reload a SENT *module* file -- one that references the global `ENT` (e.g. `function ENT:Foo()` or `ENT:AddHook(...)`), which is nil under a bare include and would error; the tool points `ENT` at the live registered class (scripted_ents.GetStored) around the run so the edits patch the running class and its spawned instances, then restores it. `force_compile`: read the source fresh and CompileString it instead of include()ing, to bypass include's compiled-chunk cache (on a listen-server host client, include can re-run a stale compiled chunk for an edited file even when the disk bytes are current; force_compile always uses the current bytes). Ungated: it only re-runs code already installed in the LUA search path (no arbitrary-filesystem reach, no caller-supplied code). Run a file in its own realm -- a sv_ file via _sv, a cl_ file via _cl, a sh_ file via both realms. Returns ok/path and any values the file returned. (On a listen-server host the client realm's file view is the boot-time snapshot, so reloading a clientside file there is best-effort: a file added since boot may be invisible (not found); an edited file may need force_compile to pick up the change. The server realm always reads fresh from disk.) Runs in both realms.",
    schema = {
        type = "object",
        properties = {
            path = {
                type = "string",
                description = "Lua file path relative to a lua/ search root (the path include() takes), e.g. \"autorun/server/myfile.lua\" or \"tardis/core/sh_thing.lua\". Must exist in the LUA search path.",
            },
            ent_class = {
                type = "string",
                description = "Scripted-entity class name (scripted_ents) to bind the global `ENT` to while running the file -- needed to reload a SENT module file that defines `ENT:` methods/hooks (nil `ENT` otherwise errors). Edits patch the live class and its spawned instances. Errors if the class isn't registered.",
            },
            force_compile = {
                type = "boolean",
                description = "Read the source fresh and CompileString it instead of include(), bypassing include's compiled-chunk cache (use when an edit isn't taking on the listen-host client realm). Default false.",
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

        local forceCompile = args.force_compile == true

        -- ent_class: bind the global ENT to the live class table so a SENT module file's
        -- `ENT:` definitions apply to it. Restore the previous ENT (usually nil) after, even
        -- on error, so we don't leak a dangling global.
        local entClass = isstring(args.ent_class) and args.ent_class ~= "" and args.ent_class or nil
        local prevENT, boundENT
        if entClass then
            local stored = scripted_ents.GetStored(entClass)
            if not stored or not stored.t then
                return { ok = false, error = "no scripted entity class '" .. entClass .. "' registered" }
            end
            prevENT = _G.ENT
            _G.ENT = stored.t
            boundENT = true
        end

        local res = { runFile(path, forceCompile) }

        if boundENT then _G.ENT = prevENT end

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
        if entClass then out.ent_class = entClass end
        if forceCompile then out.force_compile = true end
        -- Surface any values the file returned (some modules return a table), like lua_run.
        if #res > 0 then
            out.returns = #res
            out.result = (#res == 1) and MCP.util.Serialize(res[1]) or MCP.util.Serialize(res)
        end
        return out
    end,
})
