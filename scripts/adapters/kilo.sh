# shellcheck shell=bash
# kilo transport adapter (OpenCode-fork; binary = kilo, model namespace = kilo/z-ai/...).
# Requires lib/timeout.sh and lib/adapter_common.sh sourced (ens_run_timeout, ens_opencode_fork_review).
# structured_output: sentinel  (verdict carried by ===VERDICT=== block in assistant text)

[ -n "${_ENS_ADAPTER_COMMON:-}" ] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/adapter_common.sh"

kilo_review() { # ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE
  local ep="$1" model="$2" eff="$3" pf="$4" of="$5"
  # effort is ignored for kilo (no native flag); ens_opencode_fork_review handles the
  # set +e / restore-e dance, timeout, JSONL extraction, and exit-code pass-through.
  ens_opencode_fork_review kilo "$model" "$pf" "$of"
}

kilo_run() { # ENDPOINT MODEL EFFORT PROMPT_FILE DIR OUT_FILE  (executor / write mode)
  local ep="$1" model="$2" eff="$3" pf="$4" dir="$5" of="$6"
  ens_opencode_fork_run kilo "$model" "$pf" "$dir" "$of"
}

kilo_health() { # -> ok | auth | missing
  command -v kilo >/dev/null 2>&1 || { echo missing; return 0; }
  local out rc
  local _e; [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  out="$(ens_run_timeout 25 -- kilo models 2>/dev/null)"
  rc=$?
  [ "$_e" -eq 1 ] && set -e || true
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    echo ok
  else
    echo auth
  fi
}

kilo_list_models() { # -> model ids, one per line
  command -v kilo >/dev/null 2>&1 || return 0
  kilo models 2>/dev/null
}
