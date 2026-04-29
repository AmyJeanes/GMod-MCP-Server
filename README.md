# GMod MCP Server

A Model Context Protocol (MCP) bridge between an AI coding assistant and a running Garry's Mod session. Lets the assistant invoke tools (e.g. run Lua, inspect state) inside the live game, instead of relying on static analysis and copy-pasted console output.

The repo is the GMod addon: clone it directly into `garrysmod/addons/`. The .NET MCP server lives in `server/` and is ignored by the GMod engine.

## Quick start

1. **Install the addon**
   ```
   cd garrysmod/addons
   git clone https://github.com/AmyJeanes/GMod-MCP-Server.git
   ```
2. **Build the MCP server**
   ```
   cd GMod-MCP-Server/server/GModMcpServer
   dotnet build
   ```
3. **Register the MCP server with your client** (e.g. Claude Code):
   ```
   claude mcp add gmod -- dotnet run --project /absolute/path/to/server/GModMcpServer
   ```
4. **Have the assistant launch GMod** via the `host_launch` tool, or start GMod yourself. The bridge polls regardless of consent, but tool dispatch requires opting in via convars in the GMod developer console:
   ```
   mcp_enable 1
   mcp_allow_lua_eval 1
   ```
   These are `FCVAR_ARCHIVE`, so once set they persist across game restarts.
5. **Verify**: `mcp__gmod__lua_run_sv` and `mcp__gmod__lua_run_cl` (game-side, dispatched through the file bridge) plus `mcp__gmod__host_launch`, `host_close`, `host_status` (host-side, run by the .NET process) should appear in your assistant's tool list. `host_status` will report `bridge.reachable: true` once GMod is running and responsive.

## How it works

GMod cannot run a listening socket from pure Lua, and `http.Fetch`/`HTTP()` block private-IP destinations on listen and singleplayer servers. This addon uses **file-based IPC** via `garrysmod/data/mcp/` — the server-realm and client-realm bridges run independent poll loops, the .NET host polls the response files, and big payloads (future: screenshots) never traverse `net.WriteString`. No binary modules required.

Each .NET MCP host generates a per-process session GUID and prefixes its request IDs with it, so multiple MCP clients (Claude Code + MCP Inspector + …) can share the same GMod instance without stealing each other's responses.

See `docs/protocol.md` for the wire format.

## Adding tools

Drop a Lua file in `lua/mcp/functions/` with the conventional `sh_/cl_/sv_` prefix. The realm is implicit from the prefix, and the framework appends `_sv`/`_cl` to the MCP tool name automatically:

```lua
MCP:AddFunction({
    id = "list_players",
    description = "List all connected players.",
    schema = { type = "object", properties = {}, required = {} },
    handler = function(args, ctx)
        local names = {}
        for _, ply in ipairs(player.GetAll()) do
            names[#names + 1] = ply:Nick()
        end
        return { ok = true, result = names }
    end,
})
```

Saving the file is enough — GMod's autorefresh re-runs it, the registry replaces the existing entry, and a debounced manifest write (100 ms) propagates the change to the .NET host, which emits `notifications/tools/list_changed`. `mcp_reload` is still available in the GMod console for forced rebuilds (e.g. when a tool file has been deleted, since autorefresh has nothing to fire on for removals).

## Capabilities (security gating)

Sensitive tools declare a `requires` list. The capability ships with an auto-derived convar (`mcp_allow_<id>`) that defaults to off:

```lua
MCP:AddCapability({
    id = "lua_eval",
    description = "Allows execution of arbitrary Lua source.",
    default = false,
})

MCP:AddFunction({
    id = "lua_run",
    requires = { "lua_eval" },
    -- ...
})
```

The bridge refuses dispatch when any required capability is off, so a buggy or compromised handler cannot bypass the gate.

## License

MIT — see `LICENSE`.
