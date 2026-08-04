# Engine console capture (`-condebug` → `console.log`)

Design + empirical findings for surfacing **engine-native** console output (the
C++ warnings Lua can't see — `Bad SetLocalOrigin`, `Crazy origin on entity`,
physics/transform sanity spew) to the MCP client.

## Why Lua can't do this

Passive capture (`sh_capture.lua`) only ever sees **Lua-originated** output: it
detours the Lua globals `print`/`Msg`/`MsgN`/`MsgC` and hooks `OnLuaError`.
Anything the engine writes to the console from C++ (`Warning`/`Msg`/`DevMsg`,
assertion/physics spew) never routes through those globals, and GMod exposes no
Lua hook for the engine console stream. So engine-native lines are structurally
invisible to `console_read` / the `events` rail.

The only route from outside the process is the engine's own `-condebug`, which
mirrors the whole console (engine **and** Lua) to `garrysmod/console.log`. The
.NET host has unrestricted filesystem access, so it tails that file. `condump`
(a Source console-dump command) does **not** exist in GMod — verified — so the
log file is the only mechanism.

## Empirical findings (verified live 2026-08-04, GMod on freespace_revolution)

Tested by launching with `host_launch(extra_args=["-condebug"])` — no code change
needed — and reading the file from disk.

1. **`-condebug` works in GMod** (not stripped like `condump`). It produces a
   `console.log` containing engine-native output — e.g. `Mounted 188 of 191
   workshop addons!`, `Failed to load custom font file ...`, `Attempting to load
   Chromium...`. This is the make-or-break; it passed.
2. **Path:** `garrysmod/console.log` (the mod dir), **not** the process working
   directory (`GarrysMod/`, where `chromium.log` lands). Resolve it as
   `<dataPath>/../console.log` (dataPath is `garrysmod/data`).
3. **Concurrent read while the engine writes: works.** Opening with
   `FileShare.ReadWrite` read the live file with no sharing violation — the #1
   risk, resolved. The engine keeps the file open for writing throughout.
4. **No realm attribution.** Server-Lua, client-Lua and engine output interleave
   in one file with no `[SV]`/`[CL]` tag (the only "server" strings seen were
   addon-authored message text). In listen/SP there is one process = one console
   = one file; two files only happen with a dedicated server (`srcds`), which
   `host_launch` never spawns. **Per-realm attribution can only come from the Lua
   rings**, which is why they stay.
5. **Lua errors appear in BOTH rails, but cleaner in the Lua one.** A passive Lua
   error lands in console.log as `[ERROR] mcp_lua_run:9: <msg>` followed by an
   indented numbered stack (multi-line); the **same** error in `console_read_sv`
   is a single structured `{"kind":"error","text":"mcp_lua_run:9: <msg>"}`. So
   the passive engine rail must **exclude `[ERROR]` lines and their stack** — the
   Lua rail already carries them, better. Engine C++ errors do **not** use the
   `[ERROR]` tag (they print as `Host_Error:` / raw text), so excluding the
   bracketed tag drops Lua errors precisely without dropping engine ones.
6. **`-condebug` APPENDS across launches — it does not truncate.** Session 2's
   file still contained session 1's output and grew from 38 KB → 76 KB. So the
   file accumulates every session; the tailer must **anchor to a per-launch byte
   offset and never read from 0**, or it re-surfaces ancient history.

Bonus finding: **console.log is noisy.** Benign texture/material/spawnmenu
warnings dominate (`Requesting texture value from var "$basetexture" ...`,
`KeyValues Error: ...`, `!!! Extended Spawnmenu: FAILED ...`). Surfacing *all*
engine lines passively would flood `events`, so the passive rail needs a
**curated allowlist** of serious signatures; the explicit read returns everything.

Allowlist tuning was validated against the real accumulated log: over 1380 lines
it surfaced exactly 2 — the induced `unreasonable position` and the literal
`Bad SetLocalOrigin(-nan(ind),...)` (the motivating case) — and none of the 1378
noise lines. The case-sensitive `NaN` signature did not false-positive on the
lowercase `-nan(ind)` in that same line.

## Locked design: keep the Lua rings, add engine as a complementary source

Evidence settles the topology: the file is combined, unattributed, and its Lua
errors are worse than the Lua rail's. So engine capture is **purely additive** —
it contributes the engine-native lines nothing else can see, and nothing existing
changes.

Three cleanly-separated views:

- **`console_read_sv` / `console_read_cl` + passive `events`** — unchanged.
  Lua-originated output, per-realm, structured `kind` (incl. clean `error`),
  always-on (no `-condebug` needed).
- **Passive engine warnings on `engine_events`** — the .NET host, on each tool
  response, tails console.log from its cursor, keeps only lines matching a
  curated warning allowlist (and never `[ERROR]`/stack/`[MCP]`), and appends them
  as `kind:"engine"`. This is the .NET-side parallel of Lua's `attachEvents`; it
  rides responses the same way, so the model notices `Bad SetLocalOrigin` without
  being asked to poll. On-demand at tool-call time — no background thread.
- **`engine_log` (host tool)** — explicit read of the raw console.log tail since a
  cursor (all lines, optional substring/regex `filter`), for "give me everything."
  Ungated (read-only file access); works even when the bridge is down.

### Session anchoring (from finding 6)

- **Host-launched game:** record `anchor = file length at launch` in shared state
  (the file isn't being written yet — `host_launch` refuses if GMod is already
  running — so it's a clean boundary). Tail from `max(anchor, cursor)`. Scopes to
  this session, boot spew included.
- **Externally-launched (Steam `-condebug`) or host restarted mid-game:** no
  launch anchor → start at current EOF on first access ("start at now", like the
  Lua session cursor). Loses this session's earlier lines but never dumps old
  sessions. Documented, honest.
- **Robustness:** if the file length ever drops below the cursor (deleted, or a
  future GMod build truncates), reset the cursor to 0. Hold back a trailing
  partial line (advance the cursor only to the last newline) so a line caught
  mid-write isn't split.
- **Growth:** the file grows unboundedly across sessions, but the tailer only ever
  reads forward from its offset, so per-call cost stays the delta, not the whole
  file. Non-destructive by default; deleting console.log before launch (or an
  untested `-conclearlog`) could bound it later if wanted.

## Launch + detection

- `host_launch` adds `-condebug` by default (one line in `LaunchTool`'s arg list).
- Capture is **detection-based, not launch-source-based**: the host reports engine
  logging as active when console.log exists and is live (recent mtime / growing),
  so it works for both host-launched games and games the user starts from Steam
  with `-condebug` in launch options.
- When it's not active, the agent tells the user to add `-condebug` to Steam launch
  options for the future and offers to relaunch with it. `host_status` surfaces the
  active/inactive state.

## Implementation status

Implemented (built + unit-tested in Release; 61/61 pass):

- [x] `LaunchTool.cs`: appends `-condebug`; anchors the session offset pre-launch.
- [x] `EngineLogReader` (pure, unit-tested): offset-anchored tail, shrink-reset,
      partial-line hold-back, bounded chunk/tail windows, Latin1 (byte==char).
- [x] `EngineLogFilter`: conservative serious-signature allowlist, `[ERROR]`/`[MCP]`
      exclusion (Lua errors stay on the cleaner Lua rail).
- [x] `EngineLog` (singleton service): path resolve, `AnchorAtLaunch`, `DrainPassive`
      (curated), `Read` (raw tail / incremental).
- [x] `EngineLogTool` (`IHostTool`, ungated): explicit raw-tail read, `since`/`cursor`,
      `limit`, `filter`, `enabled`/`path`; registered in `HostToolCatalog.ToolTypes`.
- [x] Passive `engine_events` injection at the `CallToolAsync` choke point (best-effort,
      never breaks dispatch; rides host- and bridge-tool responses alike).
- [x] `host_status`: `engine_log` block (present / recently_written / hint).
- [x] `sh_console_read.lua` + `ServerInstructionsText`: Lua-only caveat pointing at
      `engine_log` / `engine_events`.
- [x] README tool tables regenerated (6 host tools); `EngineLogTests` added.

## Deferred to a live pass (needs the rebuilt host binary running)

The live MCP server is the old Debug binary and can't be hot-swapped this session, so
these await a rebuild + relaunch: calling `engine_log` live, seeing real
`engine_events` ride a response (induce e.g. a `Bad SetLocalOrigin`), `host_status`'s
`engine_log` report, and tuning the `EngineLogFilter` allowlist against real spew. The
end-to-end `-condebug` → `console.log` mechanism itself is already verified live (the
six findings above); only the new tool code is unexercised.

## Known trade-off

`-condebug` is added unconditionally and appends forever, so `console.log` grows across
launches. Correctness is unaffected (the tailer only reads forward from its anchor), but
the file is never trimmed. If bounding it matters later, options are deleting
`console.log` pre-launch or an opt-out arg — neither implemented (non-destructive default).
