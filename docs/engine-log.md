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
  sessions. Documented, honest. Because the capture marker is then behind the
  start-at-now cursor, this path also assumes Lua capture is already active, so a
  later `[ERROR]` is treated as Lua-rail-covered rather than mis-tagged as a startup
  error (relevant the moment the rebuilt host attaches to the running game).
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
- **Shape (as built):** a separate `engine_events:` text block — its own channel, *not*
  merged into the Lua `events` array. A JSON array of `{ kind, text, count? }` — `kind` is
  `engine` or `engine_startup_error`, `count` only when a message repeated — plus a
  `+N notable (read with engine_log)` breadcrumb.
- **Cap.** At most `MaxInlineEngineEvents` (10) inlined per response; the overflow rolls
  into the breadcrumb count so a burst can't flood a response.

### Unified events stream — agreed target, deferred to the live pass

The separate block above is what's **built and tested**. But the shape decision was then
revisited: the Lua console detour records the *exact* text it sends to the console
(`print` → the same tab-joined string, `Msg` → the same concatenation), so a `console.log`
line and its enriched Lua-rail event match on **exact text** (Lua errors are a clean
substring: rail has `foo:3: msg`, file has `[ERROR] foo:3: msg` + stack). That makes
correlation reliable, so the agreed end state is a **single unified `events` stream**:

- **`console.log` is the single spine** (one source, one cursor → inherently ordered and
  deduped), and the **Lua rail becomes an enrichment side-input**: .NET consumes the Lua
  events (no longer emits them separately), buffers them, and enriches each `console.log`
  line that matches with realm + clean kind. Unmatched lines are engine-native (classified
  as today). One `events` array, in file order.
- **Timing caveat (honest):** `console.log` is drained on every response (process-wide), but
  a realm's Lua events only ride *that realm's* responses. So a client-realm Lua line drained
  on a server-realm call, before its event arrives, is shown raw (un-enriched) — never duped
  or missed (the single spine guarantees once-each), just occasionally missing its realm tag.
  Stopping a late-arriving event from re-showing its already-emitted line needs a small
  bidirectional dedup buffer (recent Lua-event texts ↔ recently-emitted line texts).
- **Firehose sub-decision (resolved 2026-08-04): fold in EVERYTHING.** The unified stream
  carries the full Lua `print`/`msg` firehose (enriched) alongside errors + engine
  warnings/startup — not just notable items. So a `console.log` line matching a Lua event is
  included and enriched; an unmatched line is engine-native and still classified (notable
  inline, benign → breadcrumb). Implication to handle in the build: a benign Lua print drained
  *before* its Lua event arrives (cross-realm lag) would momentarily look engine-benign and be
  dropped, then reappear once its event correlates — so the enrichment/correlation buffer must
  hold Lua events over a short window so benign Lua lines don't flicker. This is exactly the
  behaviour that needs the live game to tune, which is why the build is deferred there.

**Why deferred (not built blind):** unlike everything else here, this *restructures the
existing event-assembly path* (making .NET the single emitter), so a blind bug could regress
the **working** Lua `events` rail — and the timing/dedup behaviour genuinely needs the live
game to validate. It's the first item to build *with* the user in the live pass; the tested
separate-rails version stands as the baseline until then.

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
- [x] `host_status`: `engine_log` block with a **definitive `condebug`** read from the
      running process's real command line (WMI, `System.Management`) — works for a
      Steam-started game we didn't launch; plus `capturing` / `command_line` / `present`
      / `recently_written` and an on/off/stale note. (`HasCondebug` unit-tested; the WMI
      call itself is best-effort try/catch, proven live via PowerShell.)
- [x] `sh_console_read.lua` + `ServerInstructionsText`: Lua-only caveat pointing at
      `engine_log` / `engine_events`.
- [x] README tool tables (6 host tools); `EngineLogTests` (grouping, classify, passive
      partition/dedup/breadcrumb, JSON format) + `CondebugDetectionTests`. 80/80.

## Deferred to a live pass (needs the rebuilt host binary running)

The live MCP server is the old Debug binary and can't be hot-swapped this session, so
these await a rebuild + relaunch. All but the first are *verification and tuning*:

- **Build the unified events stream** (the "Unified events stream" section above) — the one
  piece of *unbuilt logic*, deliberately deferred because it restructures the working
  event-assembly path and its timing/dedup needs the live game to validate. Design is fully
  locked: full-firehose folded in, console.log as the spine, Lua rail as enrichment.
- Call `engine_log` live; see real `engine_events` ride a response (induce a
  `Bad SetLocalOrigin` / a multi-line `Crazy origin` block); confirm `host_status`'s
  `engine_log` report (esp. `condebug` for an attached vs host-launched game).
- Confirm the capture-marker partition end-to-end (a real startup error surfaces once,
  as `engine_startup_error`; post-marker `[ERROR]`s don't double-report).
- Tune the three `EngineLogFilter` lists (Signatures / NotableHints / BenignHints) and
  the indent grouper against real multi-line spew.

The end-to-end `-condebug` → `console.log` mechanism is already verified live (the seven
findings above), plus the Lua marker seam (emits to `console.log` as expected) and the WMI
command-line read (via PowerShell). Only the new .NET tool/pipeline code is unexercised.

## Known trade-off

`-condebug` is added unconditionally and appends forever, so `console.log` grows across
launches. Correctness is unaffected (the tailer only reads forward from its anchor), but
the file is never trimmed. If bounding it matters later, options are deleting
`console.log` pre-launch or an opt-out arg — neither implemented (non-destructive default).

---

## FINAL design & status (2026-08-05) — supersedes every section above

The sections above are the design *evolution*; this is what's **built + committed
(`2b550e8`, local, unpushed) + validated live**. The interim ideas — separate rails,
Lua-rail *enrichment*, the `[MCP] lua-error capture active` marker, the firehose
sub-decision, and the pre/post-MCP boot buckets — were all **tried and dropped**; don't
re-attempt them (why, below).

**One unified `events` stream, sourced from `console.log` alone.** console.log already
interleaves engine + both realms' Lua output in true order, so ordering and game-vs-engine
dedup are free. `.NET` is the single emitter (`Program.CallToolAsync` → `EngineLog.Unify`).
Each entry is `{ kind, text, count? }`:
- `kind`: `engine`; `error` (a Lua error — detected by `[ERROR]` **or a numbered stack**,
  so it catches `[<addon>]`-prefixed *load* errors, which is how GMod formats startup
  errors — see `EngineLogFilter.IsLuaError`); `job` (background-job completions, passed
  through from the Lua ring under `_mcp_passive` since they're the one thing NOT in
  console.log); `map_change` (a one-line synthetic notice that the map flipped — see the
  reset below).
- `[MCP]` lines dropped; consecutive identical collapsed with `count`; multi-line grouped
  by indentation (`EngineLogGrouping`).
- **No realm tag** — console.log is realm-blind. Use `console_read_sv/cl` for per-realm Lua.
- **Start-at-now**: `host_launch` skips boot from the passive stream (boot is on demand via
  `engine_log`).
- **Map-change reset & auto-anchor** (`EngineLogFilter.IsMapChange`): the two markers
  `---- Host_Changelevel ----` (soft) and `(Server shutting down)` (hard `map`/reset) cover
  every path — `host_changelevel`, a manual console `changelevel`/`map`, and the two-stage
  bootstrap's `map` transition. **Tool-driven** changes `Anchor()` before the command, so
  their own response skips the boot cleanly (start-at-now) and reports it via `startup_log`.
  A **console-driven** change has no anchor, so when the passive drain *reaches* a marker it
  auto-anchors: it drops the old map's tail, **jumps the cursor to now (skipping the incoming
  boot — on-demand via `engine_log`)**, and emits a single `map_change` notice in place of the
  ~200-line flood. So an agent that does a raw `map x` sees "the map changed" on its next call,
  not the whole new boot. (Caveat: a call landing *mid-boot* catches the boot tail on the
  following drain — rare; the common "next call after load" case is clean. Live-validated
  2026-08-05: a manual `changelevel`/`map` had flooded a single unrelated call with 100+ boot
  events before this.) The boot **scan** (`ScanBoot`) likewise resets on a marker, scoping
  `boot_lua_errors` to the FINAL map (gm_construct falls away).

**`engine_log`** (host tool, realm-independent): the raw console.log tail on demand,
`since`/`limit`/`filter` — filter applies *before* limit (so `limit` bounds matches).
Includes boot. **`host_status.engine_log.condebug`**: real from the process command line (WMI).
**`host_launch` AND `host_changelevel`** both anchor before the map boundary and, once ready,
report `startup_log` (line count + "read the full boot via engine_log") + `boot_lua_errors`
(a flat deduped list of the loaded map's distinct Lua errors). The anchor+scan is one method
each (`EngineLog.Anchor()` / `ScanBoot()`); the result-attach prose is a single shared helper
(`HostToolHelpers.AttachBootScan(result, boot, boundaryPhrase)`) so the two tools can't drift.

**Why the dropped ideas failed:** enrichment — the console.log drain runs at
response-processing time and leads the Lua event's delivery, so realm/kind enrichment fired
*inconsistently* (worse than none). Pre/post-MCP boot buckets — realm-blindness + per-realm
capture timing make a single temporal boundary wrong for one realm; unreliable. The marker —
correlation/detection made it redundant.

**Known limitation:** the same error on both realms with *different* stacks (e.g. `sound.Add`
fired server-side vs client-side) shows as two entries — different text, un-mergeable without
realm info.

### REMAINING
1. ~~**`host_changelevel` consistency**~~ **DONE + LIVE-VALIDATED** (`c038d35`; `ChangeLevelTool.cs`):
   injects `EngineLog`, calls `Anchor()` before the changelevel, and attaches `startup_log` /
   `boot_lua_errors` after ready via the shared `HostToolHelpers.AttachBootScan` — mirroring
   `LaunchTool`. (`AnchorAtLaunch` was renamed `Anchor()` since both launch and changelevel now
   call it.) 79/79 tests pass in Release. Live-validated 2026-08-05 (freespace_revolution ->
   gm_construct -> freespace_revolution): each response carried `startup_log` + `boot_lua_errors`
   (the re-fired TARDIS load errors) and **no raw-boot `events` dump**; the next call after each
   change surfaced only the ~3 genuinely-new lines, confirming start-at-now held.
2. Optional: reconcile/trim the superseded sections of this doc into the final design.
3. Then: confirm with the user, then **push** (main is ahead, unpushed; also `behind 1`
   = a benign Renovate codeql-action digest bump — rebase onto it at push time).

**Build/validate note:** live MCP host is the Debug binary; build/test with `-c Release`
(separate `bin/`) to avoid the lock. Rebuild Debug (`dotnet build -c Debug`) only while MCP
is disabled, then user re-enables. All 79 tests pass in Release.
