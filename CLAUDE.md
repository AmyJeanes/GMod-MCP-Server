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

The framework always appends `_sv` or `_cl` to the MCP tool name on the .NET side, so realm is always visible in the tool list. Don't include `_sv`/`_cl` in your `id` field. Likewise the .NET host appends `(server realm)`/`(client realm)` to every tool's `description`, so **don't state the realm in the description** — hand-writing "Server realm." is redundant (same principle as not hand-writing capability prose, below). Keep only cross-realm *semantics* worth knowing — how a `sh_` tool's `_sv` and `_cl` differ or agree (PVS divergence, client-prediction drift, identical results) — never the bare realm label.

### Client bridge runs only for the listen-server host

The client-realm bridge serves the listen/SP **host** — the machine whose `data/mcp/` the .NET host shares. `IsListenServerHost()` needs a valid `LocalPlayer()` (not available at autorun), so the client bridge starts for everyone and a non-host client (a remote player on a listen server) stops its own bridge once `LocalPlayer()` becomes valid (`clientHostGate` in `sh_filebridge.lua`). Single-player is always the host. Consequence: dual-realm readiness (and the focus fix below) assume the local game is a listen/SP host — always true for a `host_launch`-started game.

## Capabilities

Sensitive tools declare `requires = { "<cap-id>" }` (whole-tool). Capabilities are registered with `MCP:AddCapability({ id = "...", default = false })` — the framework auto-derives the convar (`mcp_allow_<id>`) and creates it `FCVAR_PROTECTED | FCVAR_DONTRECORD | FCVAR_REPLICATED | FCVAR_ARCHIVE`. Replicated so server-side toggles propagate to clients; archived so user grants persist across game restarts. Don't reach for the convar directly; let the framework gate.

To gate **one argument** of an otherwise-ungated tool, declare `arg_requires = { [argName] = { "<cap-id>" } }`. Dispatch (`MCP:CheckCapabilities`) rejects that arg when ungranted but only if it's actually present, so the rest of the tool stays callable — `player_walk`'s caller-Lua `until` is the canonical case. Gated names must be declared schema properties (typos error at registration). Per-arg gates aren't carried in the manifest; the description is how clients learn of them.

For **both** levels the framework auto-appends the human note (`Requires the \`unsafe\` capability.`) to the tool/arg `description` at registration — so **don't hand-write capability prose**; declaring `requires`/`arg_requires` is enough, and the advertised note can't drift from the gate.

Built-in capabilities live in `lua/mcp/libraries/sh_capabilities.lua` — three: **`unsafe`** (arbitrary code: `lua_run`, `console_cmd`, `cvar_set`, `debug_record`/`debug_draw`), **`player_control`** (structured tools that drive the local player: `player_set`, `player_walk`), and **`world_control`** (structured world mutation: `entity_create`/`remove`/`set`, `game_set`, `bot_spawn`/`remove`). `lua_run` and `console_cmd` share `unsafe` because they're equivalent in power (Lua can `RunConsoleCommand`; the console can `lua_run` arbitrary Lua), so a single gate is honest rather than illusory granularity. Project-specific capabilities declare their own (e.g. TARDIS's `tardis_control`).

**Two gating axes: arbitrary-code (`unsafe`) and structured mutation (a write-cap).** `unsafe` is for tools that run caller-supplied Lua or wield arbitrary convar power: `lua_run` (and its `wait_until`/`wait_seconds`/`capture` args), `console_cmd`, `cvar_set` (it can flip `sv_cheats`/`sv_allowcslua`, so it's `console_cmd`-equivalent — curated *safe* convar knobs belong in `game_set`, not here), `debug_record`/`debug_draw`, and `player_walk`'s per-arg `until`/`sample_expr`. Separately, **a structured *mutator* is gated behind a bounded write-cap** — even though a typed `entity_set`/`player_set`/`game_set` can only do what its schema allows, *whether it may change the game at all* is the user's consent to give: **`player_control`** gates the tools that drive/reposition the local player (`player_set`, `player_walk`), **`world_control`** gates world mutation (`entity_create`/`remove`/`set`, `game_set` on both realms, `bot_spawn`/`remove`). Player is split off because it takes over the user's own avatar. **Reads are always ungated** — `entity_state`/`find`, `player_state`/`trace`, `game_state`, `cvar_state`, `world_trace`, `model_info`, `console_read`, `screenshot`, and the `debug_clear` janitor; `reload_file` is ungated too, since it re-runs already-installed on-disk code with no caller-supplied Lua. All caps default `false` (opt-in; archived so a grant persists). A tool that both reads and mutates gates on the mutation. Layering composes: `player_walk` needs `player_control` to run at all *and additionally* `unsafe` for its `until`/`sample_expr` args (whole-tool `requires` checked first, then per-arg).

## Deferred waits (RunFor / Settle)

A handler that must wait for an effect across frames defers (`return ctx.deferred`) and resolves later via `ctx.respond`. Two shared primitives in `lua/mcp/libraries/libraries/sh_runfor.lua` drive these — both RealTime + `Think`, never `timer.Simple`:

- `MCP:RunFor(opts, onDone)` — the base bounded per-frame loop: runs `on_each(elapsed)` and/or polls `stop(elapsed)` each frame up to `seconds`; resolves once with `reason` = `stop` / `duration` / `error` (`on_each`/`stop` are pcall'd; a throw ends it as `error`). The windowed-loop core for sample-per-frame tools.
- `MCP:Settle(opts, onDone)` — layered on RunFor: resolves when `check(elapsed)` has held **continuously** for `stable_for` (the dwell, so a transient blip can't false-settle), else times out. The caller supplies `check` because the harness can't know what "settled" means — velocity for poses, existence for removes. `settled = (reason == "stop")`.

A tool's `seconds` must sit under its declared `timeout` (per-tool request timeout) or the .NET host abandons the call before the wait finishes. **Gate stillness on velocity, not per-frame position** — a from-rest drop starts at ~0 speed, so a position gate false-settles before the fall accelerates. Consumers: `player_set`, `bot_remove`. (`bot_spawn`'s multi-phase respawn is a deliberately frame-counted state machine, not a settle, so it stays hand-rolled.)

## Tooling

- `.luarc.json` configures sumneko-LuaLS with `./.tools/glua-api` (GLua type stubs).
- `.tools/` is gitignored. Run `pwsh scripts/install-tools.ps1` once to populate it with the pinned `glua_ls` / `glua_check` binaries and the GLua API stubs — see "First-time setup" below. `install-tools.ps1` is a thin wrapper over the shared `gmod-addon-tools` module, cloned as a sibling (`../gmod-addon-tools`).

### Claude Code LSP integration (`glua-lsp` plugin)

Diagnostics, hover, and jump-to-definition are provided via the `glua-lsp` plugin (marketplace: `AmyJeanes/gmod-claude-plugins`), which wraps the `glua_ls` language server. `.claude/settings.json` declares the marketplace so contributors get prompted to install on first open.

#### First-time setup (do this before touching `.lua` files)

`scripts/install-tools.ps1` is a thin wrapper over the shared `gmod-addon-tools` module (`Install-GmodTools`), which is the single source of truth for the pinned `glua_check`, `glua_ls`, and GLua-API-stub versions — pinned once there for every consumer addon, so local and CI run the exact same engine. `scripts/bootstrap.ps1` resolves the module from a sibling clone (`../gmod-addon-tools`) and throws a clone hint if it's missing.

In a fresh clone, clone the module beside this addon, then run install-tools once before touching `.lua` files:

```bash
git clone https://github.com/AmyJeanes/gmod-addon-tools ../gmod-addon-tools
pwsh -File scripts/install-tools.ps1
```

It is idempotent — re-running is a no-op when the pinned versions are already present, so it's also the recovery path when LSP diagnostics look wrong. The `glua-lsp` Claude Code plugin auto-resolves `glua_ls` from this project's `.tools/bin/` at LSP launch (no PATH plumbing needed); after a fresh install just `/reload-plugins`.

To bump the tooling versions: edit the `$GluaLsVersion` / `$GluaApiVersion` constants in `gmod-addon-tools`'s `src/install.ps1` and cut a new tag there, then bump the `gmod-addon-tools` `ref:` in `.github/workflows/ci.yml`. Renovate (`.github/renovate.json` customManager on the workflow `ref:`) raises that tag bump automatically, gated by the GLua Check CI job.

The `glua-lsp:install-glua-ls` skill covers the same recovery flow if symptoms appear later.

#### Workspace-wide scans with `glua_check`

`glua_ls` only analyzes files as they are opened/edited. To audit the whole repo at once, use `scripts/glua-check.ps1` — it installs the pinned tooling on demand (no-op when present) and runs `glua_check --warnings-as-errors` against the repo. CI calls the same script.

```bash
pwsh -File scripts/glua-check.ps1
```

`glua_check` only accepts a workspace root, not file/path filters, so the script always scans the whole repo.

Useful when a fix has rippled across the codebase or when picking up the project to find latent issues the LSP hasn't surfaced yet.

## .NET side

Built with the official `ModelContextProtocol` C# SDK + Generic Host. `server/GModMcpServer/Program.cs` wires `.AddMcpServer().WithStdioServerTransport()`, watches `garrysmod/data/mcp/manifest_server.json` and `manifest_client.json` (one per realm; the host merges them), and forwards `tools/call` requests through `FileBridge`.

```bash
cd server/GModMcpServer
dotnet build
dotnet run    # for local development
```

**Building requires no MCP host holding these binaries open.** A running host — `dotnet run`, or the GMod MCP server registered in *any* Claude Code / MCP Inspector session pointed at this build — keeps `bin/.../GModMcpServer.dll` locked, so `dotnet build` / `dotnet test` fails with a file-in-use error. Disable or stop the MCP server in **every** active session (and anywhere else it's running) before building, then re-enable it after.

Tests live in `server/GModMcpServer.Tests/` (NUnit 4). Run with `dotnet test server/GModMcpServer.Tests/GModMcpServer.Tests.csproj` from the repo root. Coverage focuses on `MergedManifest.Equals`, `FileBridge` round-trips against a `FakeGmodResponder`, and `ManifestWatcher` change detection. `GameProcessManager` and the host tools (`Launch`/`Close`/`Status`) aren't unit-tested — they wrap the OS process layer and the live file bridge respectively.

Two categories of tool exist on the .NET side:
- **Host tools** (`server/GModMcpServer/Host/Tools/`) — implemented in-process, available even when GMod isn't running: `host_launch`, `host_close`, `host_status`. `host_changelevel` also lives here but needs a running game — it changes the live map and blocks until the new map is ready (the in-game sibling of `host_launch`'s readiness wait). `mcp_reload` is also here — the host-managed addon reload (re-runs the Lua, restarts the bridge, then waits for both realms via the `_generation` bump in `_ping`); it's named for the console command it wraps, *not* `host_*`, because it reloads the addon, not the game. It exists because the bare console `mcp_reload` tears the bridge down mid-call and times out the triggering caller.
- **Bridge tools** — declared by GMod via `MCP:AddFunction`, dispatched through the file IPC. Names always end in `_sv` or `_cl` so realm is visible.

`host_status` issues a live `_ping` round-trip when GMod is detected so the MCP client can distinguish "running but bridge unreachable" from "running but `mcp_enable` is off." See `docs/protocol.md` for the wire format.

### Tool-list generation (README)

The **Tools** tables in `README.md` are auto-generated — the prose around them is normal README text, but the three tables (between the `<!-- TOOLS:HOST -->`, `<!-- TOOLS:GAME -->`, `<!-- TOOLS:CAPS -->` marker pairs) are not hand-edited. `server/GModMcpServer.ToolList` builds them game-independently: it reflects the host tools via `HostToolCatalog.Describe()` and recovers the GMod bridge tools by running the addon's registration code headlessly under MoonSharp (`LuaToolDump` stubs the few globals touched at file-load, loads `sh_` in both realms, then calls the real `MCP:BuildManifest()`). MoonSharp is a dependency of the generator only, never the shipping server.

`HostToolCatalog.ToolTypes` is the single source of truth for host tools — Program.cs registers DI from it and the generator reflects from it, so a new host tool is picked up by both. Regenerate with `dotnet run --project server/GModMcpServer.ToolList` (`--check` exits non-zero if stale, for CI). The `tool-list.yml` workflow regenerates and auto-commits on push to main.

## Hot reload

Editing an existing Lua tool file is enough — no console command needed. GMod's autorefresh re-runs the file, `MCP:AddFunction` is idempotent and updates the registry in place, then a debounced 100 ms timer writes a fresh manifest. The .NET host's `ManifestWatcher` notices the content delta and pushes `notifications/tools/list_changed` to the connected MCP client.

`mcp_reload` is still available for forced rebuilds (e.g. when a tool file has been *deleted* — autorefresh has nothing to fire on for removals, and for a brand-*new* file on **either realm**, which `mcp_reload` picks up because `MCP:Reload` re-runs `LoadFolder("functions")` in both realms — on the listen/SP host the client `include`s new files straight off the shared disk, so a brand-new *client* tool hot-loads with no relaunch too, verified 2026-06-30 with `entity_find_cl`). It comes in two forms: the in-game console command, and the host-managed `mcp_reload` MCP tool (above) which waits for the bridge to come back — prefer the tool from an MCP client, since the bare console reload restarts the bridge mid-call and times the caller out.

**Adding, renaming, or removing a tool now propagates mid-session — no restart needed.** We advertise `capabilities.tools.listChanged: true` (set in `Program.cs` via a post-`Configure`; the SDK's manual `WithListToolsHandler` path leaves the flag off, only the attribute/collection path auto-sets it). With it advertised, the manifest-delta `notifications/tools/list_changed` actually takes effect: verified live 2026-06-29 on Claude Code v2.1.195 — a runtime-registered tool was callable **within the same turn**, and a removed one vanished. The old "must restart" belief was *our* bug, not Claude Code's: CC correctly gates on the advertised capability, which we never sent. CC's handling of it has been historically flaky (anthropics/claude-code#4118, #31893), so a restart stays the fallback if a new tool ever fails to appear. Game-side caveat unchanged: a brand-*new* file (or a deletion) still needs `mcp_reload` to load/clear it — autorefresh only fires for edits to existing files — but once the manifest changes, CC picks it up without a restart. *Editing the body of an already-registered tool* needs nothing — autorefresh updates the handler and the known name/schema still dispatches. (Distinct from the genuinely-unsupported `notifications/message` server→model channel behind the README's "Console & error capture" workaround.)

ConVar values (capability gates, `mcp_enable`) are `FCVAR_ARCHIVE` so they persist across reloads. Persisting across a game *restart* additionally needs a clean shutdown: GMod writes its archived server convars to `cfg/server.vdf` only on a proper window-close, so `host_close` does that by default (see Process tracking) — a force-kill loses any grants set that session.

## Multi-host file IPC

Multiple .NET MCP hosts can share the same GMod data dir (e.g. Claude Code + MCP Inspector running side-by-side). Each .NET host generates a per-process session GUID at startup and prefixes every request id with `<session>__`, so the response files are filtered by glob and never poach each other. GMod treats the prefixed id as opaque and echoes it back in the response filename. Cleanup of `mcp/<realm>/in,out/` happens in `MCP:StartBridge` (init + `mcp_reload`), so crashed-host orphans are reaped on next reload — no TTL janitor needed.

## Process tracking (host_launch / host_close)

`GameProcessManager` finds GMod via `Process.GetProcessesByName("gmod")` rather than holding the handle returned by `Process.Start`. The launcher chain re-execs itself within seconds on Windows, so the original handle goes stale fast — but only one `gmod.exe` is ever running at a time (Steam blocks duplicates), so a name lookup is both reliable and survives .NET host restarts. `_lastArgs` is in-memory state — populated only when *this* .NET process called Launch — and is informational.

`host_close` defaults to a **clean** shutdown so GMod saves its config (capability grants / `mcp_enable` → `cfg/server.vdf`, written only on a real window-close). Lua can't quit (the engine blocklists `quit` on every Lua path: `game.ConsoleCommand`, `RunConsoleCommand`, `Player:ConCommand`) and a raw `WM_CLOSE` is ignored, so it posts the X-button signal (`WM_SYSCOMMAND`/`SC_CLOSE`) to the visible "Garry's Mod" window — found by enumerating top-level windows across all gmod PIDs, since the launcher spawns several (CEF/Steam helpers) and `MainWindowHandle` is unreliable. It waits up to `graceful_seconds` (default 10) for the tree to exit, then falls back to a kill; `force: true` skips straight to the kill (no config save). The clean path is Windows-only (`OperatingSystem.IsWindows()`-guarded); other platforms kill.

### Focus handling on launch (`host_launch` `background`)

GMod grabs the OS foreground at **window creation** (early, well before bridge readiness). Whether that's wanted depends on intent, so a single `background` arg (Windows-only) drives all the focus handling; there is no separate `fix_focus` knob.

Everything here leans on one primitive: `GameProcessManager.SetForegroundForced` — a `SetForegroundWindow` wrapped in the **`AttachThreadInput` trick** (attach our input queue to the *current* foreground window's thread for the call; it may even report false yet still take effect). A *plain* `SetForegroundWindow` from this long-lived background host is **silently blocked by Windows' foreground lock** whenever another process holds/asserts the foreground — GMod during its startup grab (live: 51 futile demotes, GMod held ~7 s), OR a window the user is actively clicking (live: 4 plain flickers failed mid-click and the mouse stayed stuck). The forced version wins in one shot, with a **clean refocus afterwards** (no FPS/mouse-look corruption — unlike the **rejected** synthetic `WM_KILLFOCUS`/`WM_ACTIVATE` deactivate messages, which free the mouse but wreck the next real refocus).

`background: false` (**default**, "foreground launch"): GMod is allowed to come to the front. After readiness, `ReconcileFocusAsync` checks for the **stuck-mouse glitch** — the GMod/SDL bug where, if focus is lost during the startup race, GMod misses the OS focus-lost event, keeps its cached focus flag "focused", and grabs the mouse (relative-mouse recenter) *while backgrounded*. Signature: `GameProcessManager.IsForeground()` false **and** the client realm's `_ping` `has_focus = true` (a *clean* background, `has_focus = false` — e.g. the user deliberately alt-tabbed away — is not the glitch and is left alone). On a hit it heals by bringing GMod **legitimately to the foreground** (`FocusGame`), so the mouse grab is correct because the game really is the active window — consistent with "foreground launch". `has_focus` lies (stays true) during the glitch, so it's only a *detector*, never trusted as truth.

`background: true` ("keep my window", for the MCP-from-fullscreen-RDP workflow): never steal focus. `host_launch` captures `CaptureForegroundWindow()` *before* `Launch`, then a concurrent watcher (`WatchForegroundAsync`, ~120 ms) calls `DemoteFromForeground(userWindow)` throughout the readiness wait, restoring the user's window whenever GMod grabs it. A **single** forced restore sticks (GMod asserts the foreground only once, at creation, and doesn't re-grab), leaving GMod **cleanly unfocused** (`has_focus = false`, no mouse grab); validated `demotes = 1` with a 200 ms logger **never once** catching GMod foreground. Needs `wait_for_bridge` (the watcher rides the readiness wait). The post-readiness reconcile then finds the stuck signature for this mode and would flicker (`FlickerFocus`: forced focus-in → settle → restore the user's window) to free the mouse — but in practice the watcher already prevented the stuck state, so it no-ops.

Reported back in the `background_focus` (watcher) and `focus_reconcile` (`action`: `none` / `focus_game` / `flicker`) result blocks.

`host_launch` and `host_changelevel` wait for **both** realms to report ready before returning (`BridgePinger.WaitUntilReadyAsync` polls server + client each tick, fail-fast on either realm's `bootstrap_error`). The client realm only needs to be reachable with `mcp_enable` on (bootstrap state is server-side) and is where `has_focus` comes from.
