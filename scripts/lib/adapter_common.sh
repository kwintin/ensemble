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
    if o.get("type")=="text":
        sys.stdout.write((o.get("part") or {}).get("text",""))
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
  [ "$_e" -eq 1 ] && set -e || true
  ens_jsonl_text <"$raw" >"$of"
  rm -f "$raw"
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
