-- MVP tool: execute arbitrary Lua source in the current realm.
-- Gated behind the `lua_eval` capability (mcp_allow_lua_eval).

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
    requires = { "lua_eval" },
    handler = function(args, ctx)
        local code = args.code
        if type(code) ~= "string" then
            return { ok = false, error = "missing or non-string `code` argument" }
        end

        local fn = CompileString(code, "mcp_lua_run", false)
        if type(fn) == "string" then
            return { ok = false, error = "compile error: " .. fn }
        end

        local ok, ret = pcall(fn)
        if not ok then
            return { ok = false, error = "runtime error: " .. tostring(ret) }
        end

        return {
            ok = true,
            result = ret == nil and "" or tostring(ret),
        }
    end,
})
