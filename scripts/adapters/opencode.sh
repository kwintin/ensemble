# shellcheck shell=bash
# opencode transport adapter (DeepSeek V4 Pro via opencode-go fork).
# Requires lib/timeout.sh + lib/adapter_common.sh sourced (ens_run_timeout,
# ens_opencode_fork_review, ens_sentinel_prompt).  Effort is ignored: the
# opencode CLI has no native effort knob.

[ -n "${_ENS_ADAPTER_COMMON:-}" ] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/adapter_common.sh"

opencode_review() { # ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE
  local _ep="$1" model="$2" _eff="$3" pf="$4" of="$5"
  # ens_opencode_fork_review handles: set+e dance, timeout guard, JSONL extraction,
  # sentinel-prompt wrapping, stderr passthrough, and exit-code propagation.
  ens_opencode_fork_review opencode "$model" "$pf" "$of"
}

opencode_run() { # ENDPOINT MODEL EFFORT PROMPT_FILE DIR OUT_FILE  (executor / write mode)
  local _ep="$1" model="$2" _eff="$3" pf="$4" dir="$5" of="$6"
  ens_opencode_fork_run opencode "$model" "$pf" "$dir" "$of"
}

opencode_health() { # -> ok | auth | missing
  command -v opencode >/dev/null 2>&1 || { echo missing; return 0; }
  local out rc
  local _e; [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  out="$(ens_run_timeout 25 -- opencode models 2>/dev/null)"
  rc=$?
  [ "$_e" -eq 1 ] && set -e || true
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    echo ok
  else
    echo auth
  fi
}

opencode_list_models() { # -> model ids, one per line (best-effort)
  command -v opencode >/dev/null 2>&1 || return 0
  opencode models 2>/dev/null
}
