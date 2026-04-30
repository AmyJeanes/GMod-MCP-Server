# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Two-part project: a GMod addon (`lua/`) and a .NET MCP server (`server/`). The repo IS the addon — `git clone` directly into `garrysmod/addons/` and GMod loads it. Anything outside `lua/`, `materials/`, `models/`, `sound/`, `resource/`, and the `addon.json` is ignored by the engine.

The bridge between the two halves is **file-based IPC** under `garrysmod/data/mcp/`. Pure Lua on the GMod side — no binary modules. See `docs/protocol.md` for the wire format.

## Code style

- Pure Lua syntax only — **no GMod-Lua extensions**: no `//` comments, no `continue`, no `!=`, etc.
- Keep changes minimal and focused. Comment only genuinely non-obvious code.
- Any `---@diagnostic disable` / `disable-next-line` directive must be paired with a short comment explaining *why* the rule is suppressed. The default expectation is to fix the issue, not suppress it.

## Module system

`lua/autorun/mcp.lua` bootstraps everything via `MCP:LoadFolder` with `sh_/cl_/sv_` prefix dispatch. Load order is intentional, deepest libraries first:

```
MCP:LoadFolder("libraries/libraries")
MCP:LoadFolder("libraries")
MCP:LoadFolder("functions")
```

Adding a library something else depends on means putting it deep enough that it loads first.

### Realm is implicit from file prefix

A `sh_lua_run.lua` is included on both server and client, so `MCP:AddFunction` runs once per realm. Don't add a `realm` field to the registration table — the framework reads `SERVER`/`CLIENT`. `sv_*` and `cl_*` files only register on their respective realm.

### Tool naming

The framework always appends `_sv` or `_cl` to the MCP tool name on the .NET side, so realm is always visible in the tool list. Don't include `_sv`/`_cl` in your `id` field.

## Capabilities

Sensitive tools declare `requires = { "<cap-id>" }`. Capabilities are registered with `MCP:AddCapability({ id = "...", default = false })` — the framework auto-derives the convar (`mcp_allow_<id>`) and creates it `FCVAR_PROTECTED | FCVAR_DONTRECORD | FCVAR_REPLICATED | FCVAR_ARCHIVE`. Replicated so server-side toggles propagate to clients; archived so user grants persist across game restarts. Don't reach for the convar directly; let the framework gate.

Built-in capabilities live in `lua/mcp/libraries/sh_capabilities.lua`. Project-specific capabilities declare their own.

## Tooling

- `.luarc.json` configures sumneko-LuaLS with `./.tools/glua-api` (GLua type stubs).
- `.tools/` is gitignored. Populate it once with the GLua API stubs before the LSP can produce useful diagnostics — see "First-time setup" below.

### Claude Code LSP integration (`glua-lsp` plugin)

Diagnostics, hover, and jump-to-definition are provided via the `glua-lsp` plugin (marketplace: `AmyJeanes/gmod-claude-plugins`), which wraps the `glua_ls` language server. `.claude/settings.json` declares the marketplace so contributors get prompted to install on first open.

#### First-time setup (do this before touching `.lua` files)

If you're operating in a fresh clone, check both of these and install whichever is missing — otherwise diagnostics will be either absent or full of noise:

1. **`glua_ls` binary on PATH**
   ```bash
   glua_ls --version
   ```
   If missing or outdated, install it from the latest
   [`Pollux12/gmod-glua-ls`](https://github.com/Pollux12/gmod-glua-ls) GitHub release,
   not Cargo. The crates.io packages can lag the release binaries used by CI.

   Windows PowerShell example:
   ```powershell
   New-Item -ItemType Directory -Force .tools/glua-ls
   $url = gh api repos/Pollux12/gmod-glua-ls/releases/latest `
       --jq '.assets[] | select(.name == "glua_ls-win32-x64.zip") | .browser_download_url'
   Invoke-WebRequest -Uri $url -OutFile .tools/glua_ls.zip
   Expand-Archive -Path .tools/glua_ls.zip -DestinationPath .tools/glua-ls -Force
   ```
   Add `.tools/glua-ls` to the PATH used by Claude Code, or place `glua_ls.exe` in another PATH directory, then re-run `glua_ls --version`.

2. **GLua API stubs at `.tools/glua-api/`**
   ```bash
   ls .tools/glua-api/_globals.lua
   ```
   If missing:
   ```bash
   mkdir -p .tools/glua-api
   url=$(gh api repos/luttje/glua-api-snippets/releases/latest \
       --jq '.assets[] | select(.name | endswith(".lua.zip")) | .browser_download_url')
   curl -sL -o .tools/glua-api.zip "$url"
   unzip -q -o .tools/glua-api.zip -d .tools/glua-api/
   ```

After installing either piece, run `/reload-plugins` so Claude Code re-spawns the LSP.

#### Workspace-wide scans with `glua_check`

`glua_ls` only analyzes files as they are opened/edited. To audit the whole repo at once, use the CLI sibling `glua_check` — same engine, same `.luarc.json`, but scans every file. Install it from the latest `Pollux12/gmod-glua-ls` GitHub release into `.tools/glua-check/`, matching the source CI uses:

```powershell
New-Item -ItemType Directory -Force .tools/glua-check
$url = gh api repos/Pollux12/gmod-glua-ls/releases/latest `
    --jq '.assets[] | select(.name == "glua_check-win32-x64.zip") | .browser_download_url'
Invoke-WebRequest -Uri $url -OutFile .tools/glua_check.zip
Expand-Archive -Path .tools/glua_check.zip -DestinationPath .tools/glua-check -Force
```

```bash
.tools/glua-check/glua_check.exe .
```

Run from the project root. The `.` is required on Windows, and the working directory must be the project root so `.luarc.json`'s relative paths resolve.

## .NET side

Built with the official `ModelContextProtocol` C# SDK + Generic Host. `server/GModMcpServer/Program.cs` wires `.AddMcpServer().WithStdioServerTransport()`, watches `garrysmod/data/mcp/manifest_server.json` and `manifest_client.json` (one per realm; the host merges them), and forwards `tools/call` requests through `FileBridge`.

```bash
cd server/GModMcpServer
dotnet build
dotnet run    # for local development
```

Tests live in `server/GModMcpServer.Tests/` (NUnit 4). Run with `dotnet test server/GModMcpServer.Tests/GModMcpServer.Tests.csproj` from the repo root. Coverage focuses on `MergedManifest.Equals`, `FileBridge` round-trips against a `FakeGmodResponder`, and `ManifestWatcher` change detection. `GameProcessManager` and the host tools (`Launch`/`Close`/`Status`) aren't unit-tested — they wrap the OS process layer and the live file bridge respectively.

Two categories of tool exist on the .NET side:
- **Host tools** (`server/GModMcpServer/Host/Tools/`) — implemented in-process, available even when GMod isn't running: `host_launch`, `host_close`, `host_status`.
- **Bridge tools** — declared by GMod via `MCP:AddFunction`, dispatched through the file IPC. Names always end in `_sv` or `_cl` so realm is visible.

`host_status` issues a live `_ping` round-trip when GMod is detected so the MCP client can distinguish "running but bridge unreachable" from "running but `mcp_enable` is off." See `docs/protocol.md` for the wire format.

## Hot reload

Editing an existing Lua tool file is enough — no console command needed. GMod's autorefresh re-runs the file, `MCP:AddFunction` is idempotent and updates the registry in place, then a debounced 100 ms timer writes a fresh manifest. The .NET host's `ManifestWatcher` notices the content delta and pushes `notifications/tools/list_changed` to the connected MCP client.

`mcp_reload` is still available for forced rebuilds (e.g. when a tool file has been *deleted* — autorefresh has nothing to fire on for removals).

ConVar values (capability gates, `mcp_enable`) are `FCVAR_ARCHIVE` so they persist across reloads and across game restarts.

## Multi-host file IPC

Multiple .NET MCP hosts can share the same GMod data dir (e.g. Claude Code + MCP Inspector running side-by-side). Each .NET host generates a per-process session GUID at startup and prefixes every request id with `<session>__`, so the response files are filtered by glob and never poach each other. GMod treats the prefixed id as opaque and echoes it back in the response filename. Cleanup of `mcp/<realm>/in,out/` happens in `MCP:StartBridge` (init + `mcp_reload`), so crashed-host orphans are reaped on next reload — no TTL janitor needed.

## Process tracking (host_launch / host_close)

`GameProcessManager` finds GMod via `Process.GetProcessesByName("gmod")` rather than holding the handle returned by `Process.Start`. The launcher chain re-execs itself within seconds on Windows, so the original handle goes stale fast — but only one `gmod.exe` is ever running at a time (Steam blocks duplicates), so a name lookup is both reliable and survives .NET host restarts. `_lastArgs` is in-memory state — populated only when *this* .NET process called Launch — and is informational.
