-- Built-in capabilities. Project-specific capabilities should be declared
-- in their own modules under lua/mcp/ or in dependent addons.

MCP:AddCapability({
    id = "lua_eval",
    description = "Allows execution of arbitrary Lua source code submitted via MCP.",
    default = false,
})
