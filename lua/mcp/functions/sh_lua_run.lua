-- MVP tool: execute arbitrary Lua source in the current realm.
-- Gated behind the `unsafe` capability (mcp_allow_unsafe).

-- GMod is Lua 5.1 (no table.pack), so capture the return count via select —
-- this stays correct even when the call ends in trailing nils.
local function packResults(ok, ...)
    return ok, select("#", ...), { ... }
end

MCP:AddFunction({
    id = "lua_run",
    description = "Compile and execute Lua source in this realm. Use `return <expr>` to get a value back.",
    schema = {
        type = "object",
        properties = {
            code = {
                type = "string",
                description = "Lua source to execute. Use `return <expr>` to capture a value.",
            },
        },
        required = { "code" },
    },
    requires = { "unsafe" },
    handler = function(args, ctx)
        local code = args.code
        if type(code) ~= "string" then
            return { ok = false, error = "missing or non-string `code` argument" }
        end

        local fn = CompileString(code, "mcp_lua_run", false)
        if type(fn) == "string" then
            return { ok = false, error = "compile error: " .. fn }
        end

        -- The bridge serializes the raw return values, so a returned
        -- table/Entity/Vector comes back structured rather than as `table: 0x…`.
        local ok, count, rets = packResults(pcall(fn))
        if not ok then
            return { ok = false, error = "runtime error: " .. tostring(rets[1]) }
        end

        local result
        if count == 1 then
            result = rets[1]
        elseif count > 1 then
            result = {}
            for i = 1, count do result[i] = rets[i] end
        end

        return { ok = true, returns = count, result = result }
    end,
})
