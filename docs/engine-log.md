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
7. **Repeated lines are written raw — no in-place rewrite.** The console's `(xN)`
   collapse of consecutive identical lines is render-only; `console.log` gets every
   occurrence verbatim (verified: 6 identical `MsgN`s → 6 lines, no counter). So the
   file is **strictly append-only** — no tail is ever seeked-back and overwritten —
   which keeps the forward-only cursor safe (it never reads mutated bytes, and the
   length never shrinks from dedup, so the shrink-reset can't misfire). The flip
   side: a per-frame warning spams the file, so the **passive rail collapses
   consecutive identical lines with a count** (mirroring the console); `engine_log`
   stays raw.

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

### Rejected: classifying by console colour (don't re-attempt)

The GMod console colour-codes by severity (red errors, yellow warnings, white
normal), which would be a perfect severity marker — but it is **not recoverable**.
Verified 2026-08-04: `console.log` is pure plain text, **zero** ANSI/colour bytes
and zero non-text bytes (the `Bad SetLocalOrigin` line is bare ASCII, no wrapper) —
`-condebug` applies colour only at console render time, it isn't stored. Nor is it
reachable another way: the `-console` window is engine-rendered VGUI (not a
readable conhost), and GLua has no engine-console-output hook (`OnLuaError` is Lua
errors only; engine C++ `Warning`/`Error` don't pass through the Lua `Msg` globals
we detour). Capturing the colour/severity would require hooking the engine spew
function from a **binary module** (banned — pure Lua only) and cross-process from
the .NET host regardless. So passive classification is stuck with text heuristics,
which is exactly why the passive rail must never drop silently (below).

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

## Passive rail refinements (design review 2026-08-04)

Stress-testing the passive rail surfaced four refinements, now **implemented** (the
pattern lists still get tuned live against real spew — that part needs real multi-line
formats and startup errors). They turn the allowlist into a *highlighter* (never the
sole gate) and recreate what the console itself does:

- **Never drop silently (breadcrumb).** The allowlist can't enumerate every engine
  warning, so it must not decide whether a line is *ever* seen. Inline the allowlist
  hits, and also append a non-silent count of other notable lines since the last poll
  ("+N more, use engine_log"). Completeness comes from the breadcrumb + the
  always-complete `engine_log`, not from the allowlist being exhaustive.

- **Collapse repeats (finding 7).** The file is raw-append, so a per-frame warning
  spams it; passive collapses consecutive identical messages with a count
  (`... (x347)`), mirroring the console's own `(xN)`. `engine_log` stays raw.

- **Multi-line messages via indentation.** The log loses true message boundaries — an
  emit-time property the console keeps and the plain-text stream doesn't, so we
  *cannot* separate messages as cleanly as GMod does. Indentation is the workable
  proxy: Source multi-line messages indent their continuation lines (the `Crazy
  origin` block = header + indented `Origin:`/`Angles:`/`Velocity:`; stack traces =
  header + indented `  1. ...`). So "a message = a non-indented line plus the indented
  lines under it." Passive groups a matched header with its indented detail (so `Crazy
  origin` surfaces *with* its values) and dedups whole groups. `engine_log` stays raw.
  It's a heuristic — anything it mis-groups is still faithfully in `engine_log`.

- **Startup errors: the capture-marker partition.** The Lua error rail (`OnLuaError`)
  exists only once the MCP addon has loaded and `mcp_enable` is on — measured ~96 boot
  lines precede the first `[MCP]` marker this session — so a Lua error during early
  startup (another addon's load-time error, anything pre-MCP) is invisible to the Lua
  rail. But `console.log` has it from process boot. So MCP emits a distinct marker to
  the console the moment its Lua capture goes active, and the engine rail partitions on
  it: **before the marker**, surface `[ERROR]` lines too (startup Lua errors only
  `console.log` has, tagged `kind: engine_startup_error`); **after it**, exclude
  `[ERROR]` (the Lua rail owns them, cleaner, structured, per-realm). The marker string
  is `[MCP] lua-error capture active` (`EngineLogFilter.CaptureMarker`). The seam makes
  the two rails cover the whole error timeline with no gap and no double-report.

### Delivery contract

- **Timing is forced by the medium.** MCP has no server→model push, so engine output can
  only ride a tool response. The agent learns of a warning on its **next tool call**
  (deduped, only what's new since the last delivery); startup errors land on the
  **first** call; a warning during an idle gap waits for the next call or an explicit
  `engine_log`. There is no "when" knob.
- **Shape** (chosen 2026-08-04): a separate `engine_events:` text block — its own
  channel, *not* merged into the Lua `events` array (engine output is process-wide and
  unattributed; `events` is per-realm Lua). A JSON array of `{ kind, text, count? }` —
  `kind` is `engine` or `engine_startup_error`, `count` only when a message repeated —
  plus a `+N notable (read with engine_log)` breadcrumb.
- **Cap.** At most `MaxInlineEngineEvents` (10) inlined per response; the overflow rolls
  into the breadcrumb count so a burst can't flood a response.

## Implementation status

Implemented (built + unit-tested in Release; 71/71 pass):

- [x] `LaunchTool.cs`: appends `-condebug`; anchors the session offset pre-launch.
- [x] `EngineLogReader` (pure, unit-tested): offset-anchored tail, shrink-reset,
      partial-line hold-back, bounded chunk/tail windows, Latin1 (byte==char).
- [x] `EngineLogGrouping`: indent-based multi-line message grouping.
- [x] `EngineLogFilter`: `Classify` into Marker / McpNoise / LuaError / Warning /
      Notable / Benign — high-confidence allowlist, broad notable heuristic, benign
      denylist, `CaptureMarker`.
- [x] `EngineLog` (singleton service): path resolve, `AnchorAtLaunch` (resets the
      capture-marker state), `DrainPassive` (group → classify → startup-partition →
      dedup → `PassiveEngineResult`), `Read` (raw tail / incremental).
- [x] `EngineLogTool` (`IHostTool`, ungated): explicit raw-tail read, `since`/`cursor`,
      `limit`, `filter`, `enabled`/`path`; registered in `HostToolCatalog.ToolTypes`.
- [x] Passive `engine_events` injection at the `CallToolAsync` choke point (JSON block,
      startup/repeat kinds + counts, `+N notable` breadcrumb, inline cap; best-effort,
      never breaks dispatch; rides host- and bridge-tool responses alike).
- [x] `sh_capture.lua`: emits the `[MCP] lua-error capture active` partition marker.
- [x] `host_status`: `engine_log` block (present / recently_written / hint).
- [x] `sh_console_read.lua` + `ServerInstructionsText`: Lua-only caveat pointing at
      `engine_log` / `engine_events`.
- [x] README tool tables (6 host tools); `EngineLogTests` (grouping, classify, passive
      partition/dedup/breadcrumb, JSON format).

## Deferred to a live pass (needs the rebuilt host binary running)

The live MCP server is the old Debug binary and can't be hot-swapped this session, so
these await a rebuild + relaunch — all *verification and tuning*, no unbuilt logic:

- Call `engine_log` live; see real `engine_events` ride a response (induce a
  `Bad SetLocalOrigin` / a multi-line `Crazy origin` block); confirm `host_status`'s
  `engine_log` report.
- Confirm the capture-marker partition end-to-end (a real startup error surfaces once,
  as `engine_startup_error`; post-marker `[ERROR]`s don't double-report).
- Tune the three `EngineLogFilter` lists (Signatures / NotableHints / BenignHints) and
  the indent grouper against real multi-line spew.

The end-to-end `-condebug` → `console.log` mechanism itself is already verified live
(the seven findings above); only the new tool/pipeline code is unexercised.

## Known trade-off

`-condebug` is added unconditionally and appends forever, so `console.log` grows across
launches. Correctness is unaffected (the tailer only reads forward from its anchor), but
the file is never trimmed. If bounding it matters later, options are deleting
`console.log` pre-launch or an opt-out arg — neither implemented (non-destructive default).
