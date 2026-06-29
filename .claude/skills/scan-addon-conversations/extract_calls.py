"""Incremental extractor of lua_run/console_cmd tool calls from GMod-addon Claude conversations.

Drives the `scan-addon-conversations` skill. The Claude Code transcripts under
<projects-root>/<encoded-path>/*.jsonl are append-only, so we remember the byte size of
each file at last scan and only parse newly-appended lines on a re-run.

Everything is derived from the script's own location, so it is portable across machines:
  - repo root      = the addon dir that contains this skill (this repo lives inside garrysmod/addons/)
  - addons folder  = the repo's parent dir; sibling subdirs are the other addons
  - projects root  = ~/.claude/projects
  - a path's Claude project-dir name = every non-alphanumeric char replaced with '-'
Override any of these with --addons-dir / --projects-root / --state if your layout differs.

Usage:
  python extract_calls.py --out <dir>            # incremental scan (default), state auto-located
  python extract_calls.py --out <dir> --all      # ignore state, scan everything
  python extract_calls.py --out <dir> --dry-run  # scan but never advance the saved watermarks (test mode)
  python extract_calls.py --baseline             # record current sizes only, emit nothing

Neither --all nor --dry-run writes the watermark file, so they are safe to run for testing.

Outputs into <dir>:  _INDEX.md, _global/api_idioms.md, <addon>/chunk_NN.md (intent + code + result tag).
"""
import json, glob, os, re, sys, argparse, tempfile

INTEREST = ("mcp__gmod__lua_run_sv", "mcp__gmod__lua_run_cl",
            "mcp__gmod__console_cmd_sv", "mcp__gmod__console_cmd_cl")
CHUNK_BYTES = 110_000

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# script is <repo>/.claude/skills/scan-addon-conversations/extract_calls.py
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))


def encode_path(p):
    """Claude Code's project-dir encoding: replace every non-alphanumeric char with '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(p))


def discover_projects(addons_dir, projects_root):
    """Return [(label, project_dir)] for every addon sibling that has a Claude transcript dir."""
    out = []
    if not os.path.isdir(addons_dir):
        return out
    for name in sorted(os.listdir(addons_dir)):
        addon_path = os.path.join(addons_dir, name)
        if not os.path.isdir(addon_path):
            continue
        proj_dir = os.path.join(projects_root, encode_path(addon_path))
        if os.path.isdir(proj_dir):
            out.append((name, proj_dir))
    return out


def short(name):
    return name.replace("mcp__gmod__", "")


def result_text(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in content)
    return str(content)


def load_state(path):
    if path and os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except Exception:
            pass
    return {}


def save_state(path, state):
    if not path:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, sort_keys=True)


def read_new_lines(fpath, offset):
    """Return (lines, new_offset). If the file shrank since last scan, re-read from 0."""
    size = os.path.getsize(fpath)
    if offset > size:
        offset = 0
    if offset == size:
        return [], size
    with open(fpath, "r", encoding="utf-8", errors="replace") as fh:
        fh.seek(offset)
        data = fh.read()
    return data.splitlines(), size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--projects-root", default=os.path.expanduser("~/.claude/projects"),
                    help="Claude Code projects dir (default ~/.claude/projects)")
    ap.add_argument("--addons-dir", default=os.path.dirname(REPO_ROOT),
                    help="GMod addons folder (default = this repo's parent dir)")
    ap.add_argument("--state", default="",
                    help="scan-state json path (default = this repo's project-memory dir)")
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(),
                    "scan-addon-conversations", "scan-out"), help="output dir for chunk files")
    ap.add_argument("--all", action="store_true", help="ignore state, scan all content")
    ap.add_argument("--dry-run", action="store_true",
                    help="scan and emit chunks but do not advance the saved watermarks (safe test mode)")
    ap.add_argument("--baseline", action="store_true", help="record current sizes only; emit nothing")
    args = ap.parse_args()

    # Default state path: this repo's own Claude project-memory dir.
    state_path = args.state or os.path.join(
        args.projects_root, encode_path(REPO_ROOT), "memory", "_scan_state.json")

    projects = discover_projects(args.addons_dir, args.projects_root)
    if not projects:
        print(f"No addon conversation dirs found under {args.projects_root}\n"
              f"(addons dir: {args.addons_dir}). Pass --addons-dir / --projects-root if your layout differs.")
        return

    state = {} if args.all else load_state(state_path)
    new_state = dict(state) if not args.all else {}

    # --- baseline: stamp current sizes, write nothing ---
    if args.baseline:
        bstate = {}
        for label, proj_dir in projects:
            bstate[label] = {os.path.basename(f): os.path.getsize(f)
                             for f in sorted(glob.glob(os.path.join(proj_dir, "*.jsonl")))}
        save_state(state_path, bstate)
        total = sum(len(v) for v in bstate.values())
        print(f"BASELINE recorded for {len(bstate)} projects, {total} transcript files -> {state_path}")
        return

    os.makedirs(args.out, exist_ok=True)
    method_re = re.compile(r"(\b\w+)\s*:\s*([A-Za-z_]\w*)\s*\(")
    lib_re = re.compile(r"\b([A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*\(")
    runcc_re = re.compile(r"(?:RunConsoleCommand|ConCommand|ConsoleCommand)\s*\(\s*[\"']([^\"']+)[\"']")

    from collections import Counter
    method_calls, lib_calls, console_via_lua, console_cmds = Counter(), Counter(), Counter(), Counter()

    grand_total = 0
    summaries = []

    for label, proj_dir in projects:
        pstate = dict(state.get(label, {}))
        seen_ids = set()
        calls = []
        for f in sorted(glob.glob(os.path.join(proj_dir, "*.jsonl"))):
            fname = os.path.basename(f)
            lines, new_off = read_new_lines(f, pstate.get(fname, 0))
            new_state.setdefault(label, {})[fname] = new_off
            recs = []
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    recs.append(json.loads(line))
                except Exception:
                    pass
            results = {}
            for d in recs:
                if d.get("type") == "user":
                    for b in d.get("message", {}).get("content", []) or []:
                        if isinstance(b, dict) and b.get("type") == "tool_result":
                            results[b.get("tool_use_id")] = (bool(b.get("is_error")),
                                                             result_text(b.get("content")))
            last_text = ""
            for d in recs:
                if d.get("type") != "assistant":
                    continue
                ts = d.get("timestamp", "")
                pending = ""
                for b in d.get("message", {}).get("content", []) or []:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "text":
                        pending += " " + (b.get("text") or "")
                        last_text = b.get("text") or last_text
                    elif b.get("type") == "tool_use" and b.get("name") in INTEREST:
                        tid = b.get("id")
                        if tid in seen_ids:
                            continue
                        seen_ids.add(tid)
                        inp = b.get("input", {}) or {}
                        code = inp.get("code", inp.get("command", ""))
                        intent = re.sub(r"\s+", " ", (pending.strip() or last_text.strip()))[:300]
                        err, rtext = results.get(tid, (False, ""))
                        rtext = re.sub(r"\s+", " ", rtext)[:120]
                        calls.append(dict(ts=ts, name=b.get("name"), code=code,
                                          intent=intent, err=err, rtext=rtext))
                        if "console_cmd" in b.get("name"):
                            console_cmds[code.strip()] += 1
                        else:
                            for m in method_re.finditer(code):
                                method_calls[m.group(2)] += 1
                            for m in lib_re.finditer(code):
                                lib_calls[f"{m.group(1)}.{m.group(2)}"] += 1
                            for m in runcc_re.finditer(code):
                                console_via_lua[m.group(1).split()[0]] += 1
        calls.sort(key=lambda c: c["ts"])
        grand_total += len(calls)
        if not calls:
            summaries.append((label, 0, []))
            continue
        pdir = os.path.join(args.out, label)
        os.makedirs(pdir, exist_ok=True)
        chunk_files, idx, buf, bbytes = [], 1, [], 0

        def flush():
            nonlocal idx, buf, bbytes
            if not buf:
                return
            fn = os.path.join(pdir, f"chunk_{idx:02d}.md")
            with open(fn, "w", encoding="utf-8") as out:
                out.write(f"# {label} — new calls chunk {idx}\n\n" + "".join(buf))
            chunk_files.append(os.path.basename(fn))
            idx += 1
            buf, bbytes = [], 0

        for i, c in enumerate(calls):
            tag = ("ERR: " + c["rtext"]) if c["err"] else ("ok" + ((" -> " + c["rtext"]) if c["rtext"] else ""))
            entry = (f"## [{i}] {short(c['name'])}  ({c['ts']})\n"
                     f"intent: {c['intent']}\n```lua\n{c['code']}\n```\nresult: {tag}\n\n")
            eb = len(entry.encode("utf-8"))
            if bbytes + eb > CHUNK_BYTES and buf:
                flush()
            buf.append(entry)
            bbytes += eb
        flush()
        summaries.append((label, len(calls), chunk_files))

    with open(os.path.join(args.out, "_INDEX.md"), "w", encoding="utf-8") as out:
        out.write(f"# Scan extraction index\n\nNew lua_run/console_cmd calls this run: {grand_total}\n\n")
        for label, n, cf in summaries:
            out.write(f"## {label}\n- new calls: {n}\n- chunks: {', '.join(cf) if cf else '(none)'}\n\n")

    gdir = os.path.join(args.out, "_global")
    os.makedirs(gdir, exist_ok=True)
    with open(os.path.join(gdir, "api_idioms.md"), "w", encoding="utf-8") as out:
        out.write(f"# Idiom frequency over calls seen THIS run ({grand_total} calls)\n\n")
        out.write("## Top Lua method calls (`:Method(`)\n\n")
        for k, v in method_calls.most_common(120):
            out.write(f"{v:5d}  :{k}\n")
        out.write("\n## Top Lua library calls (`lib.func(`)\n\n")
        for k, v in lib_calls.most_common(150):
            out.write(f"{v:5d}  {k}\n")
        out.write("\n## console_cmd_* commands\n\n")
        for k, v in console_cmds.most_common(100):
            out.write(f"{v:5d}  {k}\n")
        out.write("\n## Console commands from inside Lua (RunConsoleCommand/ConCommand)\n\n")
        for k, v in console_via_lua.most_common(80):
            out.write(f"{v:5d}  {k}\n")

    saved = not (args.all or args.dry_run)
    if saved:
        save_state(state_path, new_state)

    print(f"DONE. new calls this run = {grand_total}  (out: {args.out})")
    print(f"  state {'updated' if saved else 'NOT advanced (test mode: --all/--dry-run)'}: {state_path}")
    for label, n, cf in summaries:
        if n:
            print(f"  {label}: {n} new calls, {len(cf)} chunks")
    if grand_total == 0:
        print("  (nothing new since last scan)")


if __name__ == "__main__":
    main()
