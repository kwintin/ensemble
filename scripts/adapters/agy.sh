# shellcheck shell=bash
# agy transport adapter (Antigravity — Gemini 3.5 Flash).
# Sentinel-style: model emits ===VERDICT=== APPROVED/CHANGES + ===END=== in text output.
# Requires lib/timeout.sh and lib/adapter_common.sh sourced (ens_run_timeout, etc.).

[ -n "${_ENS_ADAPTER_COMMON:-}" ] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/adapter_common.sh"

agy_review() { # ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE
  local ep="$1" model="$2" eff="$3" pf="$4" of="$5"
  # EFFORT is ignored: agy encodes effort in the model display-name.
  ens_text_cli_review "$of" -- agy -p "$(ens_sentinel_prompt "$pf")" --model "$model" --sandbox
}

agy_health() { # -> ok | auth | missing
  command -v agy >/dev/null 2>&1 || { echo missing; return 0; }
  local out rc _e; [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  out="$(ens_run_timeout 20 -- agy models 2>/dev/null)"; rc=$?
  [ "$_e" -eq 1 ] && set -e || true
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then echo ok; else echo auth; fi
}

agy_list_models() { # -> model display names, one per line
  command -v agy >/dev/null 2>&1 || return 0
  agy models 2>/dev/null | grep -v '^[[:space:]]*$' || true
}
