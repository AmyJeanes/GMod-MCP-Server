-- Built-in capabilities. Project-specific capabilities should be declared
-- in their own modules under lua/mcp/ or in dependent addons.

-- Single gate for arbitrary code execution. lua_run and console_cmd are
-- equivalent in power — Lua can RunConsoleCommand, and the console can `lua_run`
-- arbitrary Lua — so one capability covers both rather than offering illusory
-- granularity.
MCP:AddCapability({
    id = "unsafe",
    description = "Unsafe: arbitrary code execution via MCP — Lua source (lua_run) and raw console commands (console_cmd). Effectively full control of the game and host process; enable only for a trusted client.",
    default = false,
})
