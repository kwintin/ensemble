#!/usr/bin/env bash
# PostToolUse hook on Write|Edit (design spec §8): if the edited file matches the
# spec/plan/design globs, inject a one-line Ensemble-review nudge. Supports both
# Claude's direct file_path/path input and Codex apply_patch command payloads.
# Fires ONLY on those patterns. A NUDGE, never a mandate. Togglable with
# ENSEMBLE_GATE_REMINDERS (case-insensitive 0/off/false/no/disabled); globs
# overridable with ENSEMBLE_GATE_GLOBS (comma-separated fnmatch patterns). Must
# never break the tool call (always exits 0).
set -uo pipefail

_t="$(printf '%s' "${ENSEMBLE_GATE_REMINDERS:-1}" | tr '[:upper:]' '[:lower:]')"
case "$_t" in 0|off|false|no|disabled) exit 0 ;; esac

# The hook JSON for Write includes the full file body, which can exceed the env/arg
# size limit. Stash it in a temp FILE and hand python the path (not the payload).
_tmp="$(mktemp 2>/dev/null)" || exit 0
trap 'rm -f "$_tmp"' EXIT
cat > "$_tmp" 2>/dev/null || true
[ -s "$_tmp" ] || exit 0

ENS_HOOK_FILE="$_tmp" python3 - <<'PY' 2>/dev/null || true
import json,sys,os,fnmatch,re
try: data=json.load(open(os.environ["ENS_HOOK_FILE"],encoding="utf-8"))
except Exception: sys.exit(0)
ti=data.get("tool_input") if isinstance(data,dict) else None
ti=ti if isinstance(ti,dict) else {}
paths=[]
fp=ti.get("file_path") or ti.get("path") or ""
if isinstance(fp,str) and fp:
    paths.append(fp)

# Codex apply_patch puts the full patch in tool_input.command. Extract every path
# from the patch's file headers; the command may optionally include a heredoc wrapper.
command=ti.get("command")
if isinstance(command,str):
    for line in command.splitlines():
        m=re.match(r'^\s*\*\*\*\s+(?:Add|Update|Delete)\s+File:\s*(.+?)\s*$',line)
        if not m:
            m=re.match(r'^\s*\*\*\*\s+Move\s+to:\s*(.+?)\s*$',line)
        if m and m.group(1):
            paths.append(m.group(1))
if not paths: sys.exit(0)

env=os.environ.get("ENSEMBLE_GATE_GLOBS","").strip()
def matches(path):
    low=path.replace("\\","/").lower(); base=os.path.basename(low)
    if env:                            # explicit override: fnmatch the user's patterns
        pats=[g.strip().lower() for g in env.split(",") if g.strip()]
        return any(fnmatch.fnmatch(low,p) or fnmatch.fnmatch(base,p) for p in pats)
    # defaults: dir substrings (abs OR relative) + name globs
    dirs=("docs/specs/","docs/superpowers/specs/","docs/superpowers/plans/")
    names=("*spec*.md","*plan*.md","*design*.md")
    return any(d in low for d in dirs) or any(fnmatch.fnmatch(base,n) for n in names)

matched=next((path for path in paths if matches(path)),None)
if not matched: sys.exit(0)
base=os.path.basename(matched.replace("\\","/"))
msg=("Ensemble: you just edited %s. If this is a spec/plan/design you'll build on, "
     "consider the Ensemble review workflow for multi-model sign-off first "
     "(/ensemble:review in Claude Code or $ensemble:multi-model-review in Codex; "
     "request council mode for high-stakes specs)." % base)
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":msg}}))
PY
exit 0
