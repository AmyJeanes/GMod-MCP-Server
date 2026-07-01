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

-- Structured-mutation gates. Unlike `unsafe` (arbitrary code), these guard typed,
-- schema-bounded writers: the tool can only do what its schema allows, but whether it
-- may mutate the game at all is the user's consent to give. player is split from the
-- rest because it takes over the user's own avatar.
MCP:AddCapability({
    id = "player_control",
    description = "Player control: let MCP drive and reposition the local player — teleport/pose/health/loadout (player_set) and movement/aim (player_walk). Schema-bounded, but it takes over your avatar, so it is gated separately from world mutation.",
    default = false,
})

MCP:AddCapability({
    id = "world_control",
    description = "World control: let MCP mutate world state via structured tools — spawn/remove/modify entities (entity_create/remove/set), curated game knobs (game_set), and test bots (bot_spawn/remove). Schema-bounded; running arbitrary code is `unsafe`, not this.",
    default = false,
})
