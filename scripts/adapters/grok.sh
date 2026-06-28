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
  # NOTE: do NOT add 2>/dev/null here — stderr must reach model-cli's ERR file
  # so ens_classify can detect auth/quota errors on non-zero exit.
  # (ens_text_cli_review handles the set +e / restore-e dance internally.)
  ens_text_cli_review "$of" -- \
    grok -p "$(ens_sentinel_prompt "$pf")" \
    -m "$model" \
    --permission-mode plan \
    --effort "$eff2"
}

grok_run() { # ENDPOINT MODEL EFFORT PROMPT_FILE DIR OUT_FILE  (executor / write mode)
  local ep="$1" model="$2" eff="$3" pf="$4" dir="$5" of="$6"
  # --permission-mode acceptEdits is grok's write mode; --cwd sets the worktree.
  # (no 2>/dev/null — stderr must reach model-cli's ERR for auth/quota classification)
  ens_text_cli_review "$of" -- \
    grok -p "$(ens_digest_prompt "$pf")" -m "$model" --permission-mode acceptEdits --cwd "$dir"
}

grok_health() { # -> ok | auth | missing
  command -v grok >/dev/null 2>&1 || { echo missing; return 0; }
  local out rc _e; [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  out="$(ens_run_timeout 20 -- grok models 2>&1)"; rc=$?
  [ "$_e" -eq 1 ] && set -e || true
  # match the authenticated banner specifically ("You are logged in with ...");
  # a plain "logged in" substring also appears in "not logged in"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qiE "logged in (with|as|to)"; then
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
