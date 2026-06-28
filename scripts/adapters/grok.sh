# shellcheck shell=bash
# grok transport adapter. Requires lib/adapter_common.sh sourced (ens_text_cli_review,
# ens_sentinel_prompt, ens_run_timeout).

[ -n "${_ENS_ADAPTER_COMMON:-}" ] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/adapter_common.sh"

grok_review() { # ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE
  local ep="$1" model="$2" eff="$3" pf="$4" of="$5"
  # Map our effort enum to grok's {low,medium,high,xhigh,max}
  local eff2
  case "$eff" in
    minimal)            eff2=low   ;;
    low|medium|high|xhigh) eff2="$eff" ;;
    max)                eff2=max   ;;
    *)                  eff2=high  ;;
  esac
  local _e_was_set; [[ $- == *e* ]] && _e_was_set=1 || _e_was_set=0
  set +e
  # NOTE: do NOT add 2>/dev/null here — stderr must reach model-cli's ERR file
  # so ens_classify can detect auth/quota errors on non-zero exit.
  ens_text_cli_review "$of" -- \
    grok -p "$(ens_sentinel_prompt "$pf")" \
    -m "$model" \
    --permission-mode plan \
    --effort "$eff2"
  local rc=$?
  [ "$_e_was_set" -eq 1 ] && set -e || true
  return $rc
}

grok_health() { # -> ok | auth | missing
  command -v grok >/dev/null 2>&1 || { echo missing; return 0; }
  local out
  out="$(ens_run_timeout 20 -- grok models 2>&1)"
  local rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "logged in"; then
    echo ok
  else
    echo auth
  fi
}

grok_list_models() { # -> model ids, one per line
  command -v grok >/dev/null 2>&1 || return 0
  grok models 2>/dev/null \
    | grep -E '^[[:space:]]*[-*][[:space:]]+[^[:space:]]' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' \
    | sed 's/ (default)$//' \
    | awk '{print $1}'
}
