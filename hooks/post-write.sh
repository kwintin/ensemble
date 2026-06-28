#!/usr/bin/env bash
# PostToolUse hook on Write|Edit (design spec §8): if the edited file matches the
# spec/plan/design globs, inject a one-line "consider /ensemble:review" nudge.
# Fires ONLY on those patterns. A NUDGE, never a mandate. Togglable with
# ENSEMBLE_GATE_REMINDERS=0; globs overridable with ENSEMBLE_GATE_GLOBS (comma-
# separated fnmatch patterns). Must never break the tool call (always exits 0).
set -uo pipefail

case "${ENSEMBLE_GATE_REMINDERS:-1}" in 0|off|false|no|disabled) exit 0 ;; esac

# read the hook's JSON from stdin in the shell, then hand it to python via env so
# the heredoc (python's stdin) does not shadow it
ENS_HOOK_INPUT="$(cat 2>/dev/null)" || ENS_HOOK_INPUT=""
[ -n "$ENS_HOOK_INPUT" ] || exit 0

ENS_HOOK_INPUT="$ENS_HOOK_INPUT" python3 - <<'PY' 2>/dev/null || true
import json,sys,os,fnmatch
try: data=json.loads(os.environ.get("ENS_HOOK_INPUT","") or "{}")
except Exception: sys.exit(0)
ti=data.get("tool_input") if isinstance(data,dict) else None
ti=ti or {}
fp=ti.get("file_path") or ti.get("path") or ""
if not isinstance(fp,str) or not fp: sys.exit(0)
env=os.environ.get("ENSEMBLE_GATE_GLOBS","").strip()
pats=[g.strip() for g in env.split(",") if g.strip()] if env else [
    "*/docs/specs/*", "*/docs/superpowers/specs/*", "*/docs/superpowers/plans/*",
    "*spec*.md", "*plan*.md", "*design*.md",
]
low=fp.replace("\\","/"); base=os.path.basename(low)
if not any(fnmatch.fnmatch(low,p) or fnmatch.fnmatch(base,p) for p in pats): sys.exit(0)
msg=("ensemble: you just edited a spec/plan/design file (%s). Consider /ensemble:review for "
     "multi-model sign-off before building on it (or /ensemble:review --council for high-stakes specs)." % base)
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":msg}}))
PY
exit 0
