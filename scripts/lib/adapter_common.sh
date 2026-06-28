# shellcheck shell=bash
# Shared helpers for SENTINEL-style transport adapters (agy, grok, vibe, opencode,
# kilo). These CLIs emit plain assistant text (no native structured output like
# codex's --output-schema), so the review verdict is carried by a sentinel block
# the model is asked to print, and parsed by lib/verdict.sh in "sentinel" mode.
# codex does NOT use this file.
#
# Contract recap (see scripts/model-cli.sh): an adapter's <name>_review receives
# ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE, must write the model's raw review
# TEXT to OUT_FILE, let the CLI's stderr flow through (model-cli captures it for
# ens_classify auth/quota detection), and return the CLI's exit code (the timeout
# guard maps a wall-clock kill to 124).
#
# KNOWN LIMITATION (ARG_MAX): the wrapped prompt (which includes the review
# artifact, e.g. a diff) is passed as a single argv element. A very large artifact
# (approaching the OS ARG_MAX, ~1MB on macOS) can fail with E2BIG. For oversized
# reviews, scope the diff smaller. Follow-up: route via stdin / grok --prompt-file
# for the CLIs that support it (vibe cannot — it ignores stdin in -p mode).

[ -n "${_ENS_ADAPTER_COMMON:-}" ] && return 0
_ENS_ADAPTER_COMMON=1

# Wrap the user's review prompt with a read-only directive + the verdict-sentinel
# instruction. Reads PROMPT_FILE; writes the wrapped prompt to stdout.
ens_sentinel_prompt() { # PROMPT_FILE
  local pf="$1"
  cat <<'HDR'
READ-ONLY REVIEW. Do NOT edit, create, or delete any files. Do NOT apply fixes. Do NOT run multi-model consensus or invoke other reviewers. This is ONE independent review; respond with your review as text only.

--- REVIEW REQUEST ---
HDR
  cat "$pf"
  cat <<'FTR'

--- END REVIEW REQUEST ---

When finished, print your verdict on its very last lines in EXACTLY this form — one of:
===VERDICT=== APPROVED
===VERDICT=== CHANGES
followed by:
===END===
(APPROVED only if you found no issues worth fixing; otherwise CHANGES.)
FTR
}

# Wrap a delegation TASK with an executor directive + the ===DIGEST=== trailer
# instruction (delegate engine, design spec §7.5). The executor writes files in
# its current worktree and ends with a machine-readable digest.
ens_digest_prompt() { # PROMPT_FILE
  local pf="$1"
  cat <<'HDR'
You are an autonomous coding executor working INSIDE an isolated git worktree (your current working directory). Implement the task below by CREATING/EDITING files in this directory yourself — do not merely describe the changes. Keep changes scoped to the task. If a repo-root AGENTS.md exists, follow it.

--- TASK ---
HDR
  cat "$pf"
  cat <<'FTR'

--- END TASK ---

When finished, end your output with EXACTLY this trailer and nothing after it:
===DIGEST===
files: <comma-separated paths you created or modified>
decisions: <1-3 short bullets on the key choices you made>
context: <one short paragraph the verifier/next-step needs; keep bulky detail in the files>
===END===
FTR
}

# Extract assistant text from an OpenCode-fork JSON event stream (stdin -> stdout).
# Each line is a JSON event; assistant prose is in events of type "text" at
# .part.text. Malformed lines are skipped.
ens_jsonl_text() {
  python3 -c '
import sys, json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    if not isinstance(o, dict): continue           # valid JSON that is not an object
    if o.get("type")=="text":
        part=o.get("part")
        t=part.get("text") if isinstance(part, dict) else None
        if t: sys.stdout.write(str(t))
sys.stdout.write("\n")
'
}

# Shared review path for OpenCode-fork CLIs (opencode, kilo): identical interface,
# only the binary and model-id namespace differ. Captures the CLI's exit code
# (so model-cli can classify auth/quota) while extracting assistant text to OUT.
ens_opencode_fork_review() { # BIN MODEL PROMPT_FILE OUT_FILE
  local bin="$1" model="$2" pf="$3" of="$4"
  local prompt raw rc
  prompt="$(ens_sentinel_prompt "$pf")"
  raw="$(mktemp)"
  local _e; [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  # stdout (JSON events) -> raw file; stderr inherits fd2 (model-cli's ERR file)
  ens_run_timeout 600 -- "$bin" run -m "$model" --format json -- "$prompt" >"$raw"
  rc=$?
  ens_jsonl_text <"$raw" >"$of"
  rm -f "$raw"
  # restore errexit only after extraction+cleanup so a set -e caller still gets rc
  [ "$_e" -eq 1 ] && set -e || true
  return "$rc"
}

# Shared EXECUTOR (write-mode) run for OpenCode-fork CLIs (opencode, kilo): the
# executor edits files within --dir DIR and ends with the ===DIGEST=== trailer.
# Extracts the assistant text (incl. the digest) to OUT; preserves the CLI exit code.
ens_opencode_fork_run() { # BIN MODEL PROMPT_FILE DIR OUT_FILE
  local bin="$1" model="$2" pf="$3" dir="$4" of="$5"
  local prompt raw rc
  prompt="$(ens_digest_prompt "$pf")"
  raw="$(mktemp)"
  local _e; [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  ens_run_timeout 1200 -- "$bin" run -m "$model" --dir "$dir" --format json \
    --dangerously-skip-permissions -- "$prompt" >"$raw"
  rc=$?
  ens_jsonl_text <"$raw" >"$of"
  rm -f "$raw"
  [ "$_e" -eq 1 ] && set -e || true
  return "$rc"
}

# Run a plain-text CLI under the timeout guard, capturing stdout (the assistant
# response) to OUT and preserving the CLI's exit code. Pass the full argv.
# Usage: ens_text_cli_review OUT_FILE -- <cli> <args...>
ens_text_cli_review() { # OUT_FILE -- CLI ARGS...
  local of="$1"; shift
  [ "$1" = "--" ] && shift
  local rc
  local _e; [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  ens_run_timeout 600 -- "$@" >"$of"
  rc=$?
  [ "$_e" -eq 1 ] && set -e || true
  return "$rc"
}
