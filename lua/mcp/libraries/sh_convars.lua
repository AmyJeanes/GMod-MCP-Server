-- Framework convars. Capability convars (`mcp_allow_<id>`) are auto-created
-- by MCP:AddCapability in sh_module.lua / sh_capabilities.lua.

-- mcp_enable replicates server -> client so a single toggle controls both bridges.
-- FCVAR_ARCHIVE so user consent persists across game restarts.
local enableFlags = bit.bor(FCVAR_PROTECTED, FCVAR_DONTRECORD, FCVAR_REPLICATED, FCVAR_ARCHIVE)

-- mcp_poll_interval is per-realm (each side polls at its own rate).
local localFlags = bit.bor(FCVAR_PROTECTED, FCVAR_DONTRECORD, FCVAR_ARCHIVE)

if not ConVarExists("mcp_enable") then
    CreateConVar("mcp_enable", "0", enableFlags,
        "Master switch for the GMod MCP bridge. Off by default; enabled per launch via the host_launch tool, or by explicit user toggle.")
end

if not ConVarExists("mcp_poll_interval") then
    CreateConVar("mcp_poll_interval", "0.1", localFlags,
        "File polling period in seconds (default 0.1, min 0.05).")
end

if not ConVarExists("mcp_debug") then
    CreateConVar("mcp_debug", "0", localFlags,
        "MCP dispatch logging: 0=silent, 1=one-liner per request, 2=one-liner + args + result.")
end
