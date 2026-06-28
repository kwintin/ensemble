#!/usr/bin/env bash
# PostToolUse hook on Write|Edit (design spec §8): if the edited file matches the
# spec/plan/design globs, inject a one-line "consider /ensemble:review" nudge.
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
import json,sys,os,fnmatch
try: data=json.load(open(os.environ["ENS_HOOK_FILE"],encoding="utf-8"))
except Exception: sys.exit(0)
ti=data.get("tool_input") if isinstance(data,dict) else None
ti=ti or {}
fp=ti.get("file_path") or ti.get("path") or ""
if not isinstance(fp,str) or not fp: sys.exit(0)
low=fp.replace("\\","/").lower(); base=os.path.basename(low)
env=os.environ.get("ENSEMBLE_GATE_GLOBS","").strip()
if env:                               # explicit override: fnmatch the user's patterns
    pats=[g.strip().lower() for g in env.split(",") if g.strip()]
    matched=any(fnmatch.fnmatch(low,p) or fnmatch.fnmatch(base,p) for p in pats)
else:                                 # defaults: dir substrings (abs OR relative) + name globs
    dirs=("docs/specs/","docs/superpowers/specs/","docs/superpowers/plans/")
    names=("*spec*.md","*plan*.md","*design*.md")
    matched=any(d in low for d in dirs) or any(fnmatch.fnmatch(base,n) for n in names)
if not matched: sys.exit(0)
msg=("ensemble: you just edited %s. If this is a spec/plan/design you'll build on, "
     "consider /ensemble:review for multi-model sign-off first (or --council for high-stakes specs)." % base)
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":msg}}))
PY
exit 0
