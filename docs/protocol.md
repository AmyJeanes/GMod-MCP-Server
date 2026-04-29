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
      "requires": ["lua_eval"],
      "realm": "server"
    }
  ],
  "capabilities": [
    {
      "id": "lua_eval",
      "description": "Allows execution of arbitrary Lua source...",
      "default": false,
      "convar": "mcp_allow_lua_eval",
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

## Bridge-internal functions

Function ids prefixed with `_` are intercepted by the bridge before reaching `MCP:Dispatch` — they bypass the `mcp_enable` gate and don't appear in the manifest.

- `_ping` — health check used by `host_status`. Returns `{ ok = true, enabled = <mcp_enable bool>, realm = "server"|"client" }`.

## Capability gating

When a tool's `requires` list contains a capability whose convar is `0`, GMod returns:

```json
{
  "id": "...",
  "result": {
    "ok": false,
    "error": "capability disabled: lua_eval (set mcp_allow_lua_eval 1 to enable)"
  }
}
```

The handler is never reached.

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
