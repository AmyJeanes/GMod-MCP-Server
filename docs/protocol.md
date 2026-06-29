# Wire protocol

The .NET host and the GMod addon communicate via files under `garrysmod/data/mcp/`. Pure Lua on the GMod side. The .NET host uses `FileSystemWatcher` for the manifest and polls the response directory at 100 ms (FSW is unreliable for response files under load — see "Race handling").

## Two kinds of tools

The MCP server exposes two categories of tool:

- **Host tools** (`host_*`) — implemented in the .NET process itself. Don't go through the file bridge; available even when GMod isn't running. Used for things outside the game: launching the process, closing it, reporting status. Defined in `server/Host/Tools/`. Always present in `tools/list`.
- **Bridge tools** (`<id>_sv` / `<id>_cl`) — declared by the GMod addon via `MCP:AddFunction` and dispatched through the file bridge. Only present when GMod is running and `mcp_enable 1`. The protocol below covers these.

## Directory layout

```
garrysmod/data/mcp/
  manifest_server.json     # written by the SERVER realm
  manifest_client.json     # written by the CLIENT realm
  server/
    in/<id>.json           # .NET -> GMod server  (request)
    out/<id>.json          # GMod server -> .NET  (response)
  client/
    in/<id>.json           # .NET -> GMod client  (request)
    out/<id>.json          # GMod client -> .NET  (response)
```

The .NET host merges the two manifest files into a unified tool list; tool names always end in `_sv` or `_cl` to make the realm explicit on the wire.

## Manifest

```json
{
  "realm": "server",
  "generation": 3,
  "functions": [
    {
      "id": "lua_run",
      "description": "Compile and execute Lua source ...",
      "schema": { "type": "object", "properties": { "code": {...} }, "required": ["code"] },
      "requires": ["unsafe"],
      "realm": "server"
    }
  ],
  "capabilities": [
    {
      "id": "unsafe",
      "description": "Arbitrary code execution (Lua + console) — effectively full control...",
      "default": false,
      "convar": "mcp_allow_unsafe",
      "current": false
    }
  ]
}
```

Generation is incremented on every `mcp_reload`; the .NET watcher uses content-equality to decide whether to emit `notifications/tools/list_changed`.

## Request

Written by .NET into `<realm>/in/<id>.json` (atomic via `.tmp` + `File.Move`):

```json
{
  "id": "a1b2c3d4e5f60718293a4b5c6d7e8f90__0c3c8c2b9a4d4ab78f5c1d2e3f405061",
  "function_id": "lua_run",
  "args": { "code": "return 1+1" }
}
```

`id` is an opaque string the .NET host chooses. Each .NET host generates a fresh per-process session GUID at startup and prefixes every request id with `<session>__`, so two hosts sharing the same GMod data dir read only their own response files. GMod treats the id as opaque and echoes it back unchanged in the response filename. Must match `[a-zA-Z0-9._-]+` — Lua validates and discards malformed ids.

## Response

Written by GMod into `<realm>/out/<id>.json` via a single `file.Write` call (synchronous; complete when the call returns):

```json
{
  "id": "a1b2c3d4e5f60718293a4b5c6d7e8f90__0c3c8c2b9a4d4ab78f5c1d2e3f405061",
  "result": {
    "ok": true,
    "result": "2"
  }
}
```

The id (and therefore the response filename) matches the request exactly — GMod doesn't strip the session prefix.

The `result` object is whatever the function's handler returned. By convention:
- `ok: bool` — success/failure
- `result: any` — handler return value when `ok = true`
- `error: string` — error message when `ok = false`

When the .NET host sees `ok = false` in the result, it sets `isError: true` on the MCP `tools/call` response so the assistant treats it as a failure.

## Passive events / console capture

`captureRun` (sh_module.lua) captures `print`/`Msg`/`MsgN`/`MsgC` output and non-fatal `OnLuaError` warnings produced *synchronously during a handler*, and returns them as `console` (string) and `warnings` (array) on that handler's response.

Output and errors that fire **outside** a handler — a hook registered earlier, a timer, an autorefresh re-run, the async tail of a deferred handler, another addon — are recorded separately by sh_capture.lua into a bounded, per-realm in-memory ring (last ~200), each event stamped with a process-monotonic `seq`:

```json
{ "seq": 41, "time": 12.34, "kind": "error", "text": "addons/foo/lua/x.lua:5: attempt to index a nil value" }
```

`kind` is `error` (from `OnLuaError`), `print`, or `msg`. There is **no server→client push** — MCP clients (Claude Code included) don't deliver unsolicited notifications to the model — so these reach the model only on tool results, two ways:

- **Attached to the next dispatch response** as an `events` array. A per-session cursor (keyed off the `<session>__` prefix of the request id) means each connected MCP host only gets events it hasn't seen. A session's first request starts the cursor at the current high-water mark — **forward-only** — so a newly-connected host isn't handed the existing backlog (which may be another session's history); that backlog is still reachable via `console_read`. `_ping` and tools that return their own `events` (i.e. `console_read`) are left untouched.
- **Polled** via the `console_read` tool (`console_read_sv` / `console_read_cl`): args `{ since?, limit? }`, returns `{ ok, events, cursor, dropped }`. Pass the returned `cursor` back as `since` next call; `dropped` is true when events between the cursor and the oldest retained event were evicted (or were trimmed by `limit`). A `since` greater than the current max (e.g. a stale cursor after a GMod restart reset the counter) is treated as "from the start".

Capture is **realm-local** — the two realms are separate Lua states, so `_sv` responses/`console_read_sv` carry server-side events and `_cl` the client-side ones; there is no merge.

Gating: capture runs only while `mcp_enable` is `1`; the `mcp_capture` convar (`0` off / `1` errors only / `2` errors + console, default `2`) is the scope/perf knob. While inactive, the `OnLuaError` hook and console detours aren't installed, so there's no overhead. Exposure (attach + `console_read`) also routes through `MCP:Dispatch`, which gates on `mcp_enable`.

## Bridge-internal functions

Function ids prefixed with `_` are intercepted by the bridge before reaching `MCP:Dispatch` and don't appear in the manifest. Most bypass the `mcp_enable` gate (`_ping`); ones that perform an action re-check it themselves (`_changelevel`).

- `_ping` — health check used by `host_status` and the `host_launch` / `host_changelevel` readiness waits. Bypasses the `mcp_enable` gate. Returns `{ ok = true, enabled = <mcp_enable bool>, realm = "server"|"client", map = <current map>, maxplayers = <int>, singleplayer = <bool>, bootstrap_pending = <bool>, bootstrap_error = <string|absent>, has_focus = <bool, client realm only> }`. `maxplayers`/`singleplayer` let the host report listen-server vs singleplayer — and, because maxplayers is fixed at launch, signal that switching modes needs a relaunch. `bootstrap_pending` is true while a `host_launch` intent or a `_changelevel` transition is queued or mid-flight. `bootstrap_error` is set (and `bootstrap_pending` cleared) when a transition fails terminally — e.g. the target map isn't installed — so the host fails fast instead of waiting out its timeout; absent when unset. `has_focus` (`system.HasFocus()`) is present **only on the client realm** (the server has no window); the host pairs it with its own `GetForegroundWindow` check to detect and fix GMod's stuck mouse-grab after a background launch (see CLAUDE.md "Process tracking"). The readiness waits poll `_ping` on **both** realms and only return ready when both are. Older addon builds may omit the optional fields; the host decodes them as null.
- `_changelevel` — in-game map change driving `host_changelevel` (GMod side in `sv_level_change.lua`). **Server realm only**, and self-gates on `mcp_enable` (returns an error when off). Args `{ map, gamemode?, hard_reset? }`. Validates the map is installed (`maps/<map>.bsp` in mounted content), sets `bootstrap_pending`, writes the `mcp/level_change.json` marker, then issues `changelevel <map>` (or `map <map>` for a full restart / gamemode switch) at end of frame — after the response file is written. Returns `{ ok, map, command }`, or `{ ok = false, error }` if disabled or the map is missing. A map load tears down the server Lua state, so the on-disk marker is what carries `bootstrap_pending` across the teardown until the new map's `InitPostEntity` clears it; the host polls `_ping` for that, exactly like the `host_launch` bootstrap.

## Capability gating

When a tool's `requires` list contains a capability whose convar is `0`, GMod returns:

```json
{
  "id": "...",
  "result": {
    "ok": false,
    "error": "capability disabled: unsafe (set mcp_allow_unsafe 1 to enable)"
  }
}
```

The handler is never reached. The framework auto-appends `Requires the \`<cap>\` capability.` to the tool's `description` at registration, so the gate is advertised to clients (which never receive `requires` itself).

### Per-argument gates

An otherwise-ungated tool can require a capability for a single powerful argument via `arg_requires = { [argName] = { capId } }` in its `MCP:AddFunction` registration — e.g. `player_walk`'s caller-Lua `until` needs `unsafe`. The gate is checked at dispatch (after the whole-tool `requires`) but only fires when the gated arg is **actually present**, so the rest of the tool stays callable without the grant. When it does fire:

```json
{
  "id": "...",
  "result": {
    "ok": false,
    "error": "`until` requires the unsafe capability (set mcp_allow_unsafe 1 to enable); omit `until` to use the rest of the tool"
  }
}
```

Gated arg names must be declared schema properties (a typo fails loudly at registration). Per-arg gates are enforced GMod-side and aren't carried in the manifest; the requirement is conveyed to clients through the argument's schema `description`, which the framework auto-appends from `arg_requires` (authors don't hand-write it).

## Hot reload

Two paths produce a fresh manifest:

1. **Autorefresh (no console command)**: GMod re-runs an edited Lua file on save. `MCP:AddFunction` / `MCP:AddCapability` are idempotent — they replace the existing entry and schedule a debounced (100 ms) `MCP:WriteManifest`. This is the common case for editing existing tools.
2. **`mcp_reload`** (server-side console command, broadcasts a net message to clients): clears each realm's registry and re-runs the `LoadFolder` chain. Use this for forced rebuilds — e.g. when a tool file has been deleted, since autorefresh has nothing to fire on for removals.

On the .NET side, `ManifestWatcher` reloads the merged manifest whenever a `manifest_*.json` file changes, then compares the merged result by content (description, schema, requires, capability state). If anything differs, it raises `Changed`, and `BridgeHostedService` emits `notifications/tools/list_changed` to the connected MCP client via the captured `McpServer` reference.

## Race handling

- GMod's `file.Write` is synchronous; when it returns, the file is fully on disk.
- `FileBridge` on the .NET side polls `<realm>/out/*.json` at 100 ms rather than using `FileSystemWatcher`. FSW silently drops events under several Windows conditions (buffer overflow, fast file appearance after process restart). Symmetric polling — GMod is already polling at 100 ms too — is the reliable choice.
- Even with polling, the file may briefly be incomplete when the read attempt happens; `FileBridge.TryProcessAsync` retries reads up to 5 times with 10 ms backoff on `IOException`.
- .NET writes its requests as `<id>.json.tmp` then `File.Move` to `<id>.json` so GMod's `file.Find("...*.json")` only sees fully-written files.
- Cleanup is centralised on the GMod side: `MCP:StartBridge` (called on init and on `mcp_reload`) wipes both `in/` and `out/`. A .NET host shutting down also best-effort deletes its own session-prefixed files. Files left behind by a crashed host are inert (no other host's prefix matches them) and are reaped on the next `mcp_reload`.
