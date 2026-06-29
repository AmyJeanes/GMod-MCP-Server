---
name: scan-addon-conversations
description: Mine the Claude Code conversation history of the GMod addon projects under garrysmod/addons — every sibling addon plus this repo itself — for recurring raw lua_run / console_cmd patterns that would make good native MCP tools. Incremental — only re-reads transcripts that have grown since the last scan, and merges new findings into the native-tool roadmap memory. Use when the user asks to scan/re-scan addon conversations for new tooling ideas.
---

# Scan addon conversations for native-tool ideas

Find common things we keep doing through the raw `lua_run_*` / `console_cmd_*` escape hatches that deserve promotion to first-class native MCP tools (the motivating example was a "move the player naturally like in-game" tool). Findings feed the **native-tool roadmap** memory.

Runs **incrementally**: the addon `.jsonl` transcripts are append-only, so the extractor remembers each file's byte size at last scan and only re-parses newly-appended lines + brand-new conversations. A re-scan costs effort proportional to what's *new*, not the whole corpus.

## How paths are resolved (portable — nothing machine-specific)

The extractor derives everything from its own location, so this works for any user/clone:

- **repo root** = the addon dir that contains this skill (this repo lives inside `garrysmod/addons/`).
- **GMod addons folder** = the repo's parent dir; each subdir there is an addon — this repo included. Every addon with a Claude transcript dir is scanned automatically (so new addons need no edit).
- **Claude projects root** = `~/.claude/projects`. A path's project-dir name is that path with every non-alphanumeric char replaced by `-`.
- **project memory dir** = `~/.claude/projects/<encoded repo path>/memory` — where the memories below live.

Override with `--addons-dir` / `--projects-root` / `--state` only if a layout differs.

## Memories this skill reads/writes (by name, in the project memory dir)

- **`project_native_tool_roadmap`** — the living checklist of candidate native tools. New candidates are merged here; existing items get extra evidence only if it changes the picture. Preserve the status legend and don't disturb items already marked `[x]`/`[-]`/`[~]`.
- **`project_conversation_scan_state`** — human summary of the last scan (date, totals). Update it at the end of a run.
- **`_scan_state.json`** — machine-readable per-file byte high-water marks (sidecar in the memory dir, managed by the extractor; not a normal `.md` memory).

## Workflow

1. **Extract new calls.** Pick a scratch out-dir, then run from the repo root:
   ```
   python ".claude/skills/scan-addon-conversations/extract_calls.py" --out "<scratch>/scan-out"
   ```
   State auto-locates to this repo's project-memory dir. It writes `<scratch>/scan-out/<addon>/chunk_NN.md` (new calls only: intent + raw code + result tag), `_global/api_idioms.md` over this run's calls, `_INDEX.md`, and updates `_scan_state.json`. (Add `--all` for a full re-scan; `--dry-run` to scan without advancing the saved watermarks — the safe way to test the pipeline; `--baseline` records sizes without emitting. Neither `--all` nor `--dry-run` writes state, and the run prints whether state was advanced.)

2. **Stop early if nothing new.** If `_INDEX.md` reports 0 new calls, tell the user there's nothing new since the last scan (date in the scan-state memory) and stop.

3. **Read the current roadmap memory** so subagents cross-check against already-listed items and don't re-propose them.

4. **Dispatch one subagent per addon** that has new chunks (general-purpose, so they can nest). Give each: the goal above, its chunk file paths, the `_global/api_idioms.md` path, and the current roadmap item list. If an addon has many new chunks (say >4), tell that subagent to **fan out to its own sub-subagents** over batches of 3-4 chunks and synthesize. Output contract per subagent:
   - Candidate native tools (name, realm, category, what it does, recurrence + 1-2 short verbatim `[#index]` code examples, why native beats raw lua_run)
   - Each flagged **NEW** vs **already in roadmap** (and if already listed, any stronger evidence)
   - General-vs-addon-specific, and friction notes (`result: ERR` retry patterns)

5. **Merge into the roadmap memory** under the right tier; keep the checklist intact.

6. **Update the scan-state memory**: date of this scan, total new calls, per-addon new-call counts, any new candidate names added. Refresh the MEMORY.md pointer if the summary changed.

7. **Report** to the user: what was new, which candidates were added/strengthened, and what was a nothing-burger.

## Notes

- Realm rule from the codebase: tool names carry `_sv`/`_cl`; don't include realm in proposed `id` fields (see CLAUDE.md).
- Focus on patterns that **recur and generalize**; ignore one-off debugging Lua. Addon-internal implementation churn (e.g. a rendering addon's `render.*`/stencil pipeline) is not general test tooling — call it out, don't promote it.
