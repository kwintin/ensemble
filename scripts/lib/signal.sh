# shellcheck shell=bash
ens_signal() { # STATUS REASON ENDPOINT
  local status="$1" reason="$2" ep="${3:-}" retry=""
  [ "$status" = "QUOTA_EXHAUSTED" ] && retry="--continue"
  reason="$(printf '%s' "$reason" | tr '\n\r\t' '   ' | tr -d '"\\' | cut -c1-200)"
  ep="$(printf '%s' "$ep" | tr '\n\r\t' '   ' | tr -d '"\\' | cut -c1-100)"
  printf 'ENS_SIGNAL {"status":"%s","reason":"%s","endpoint":"%s","retry":"%s"}\n' \
    "$status" "$reason" "$ep" "$retry" >&2
}
# Echoes the mapped exit code AND emits the signal. Caller does: code=$(ens_classify ...)
ens_classify() { # RC STDERR_FILE ENDPOINT
  local rc="$1" ef="$2" ep="${3:-}" blob
  blob="$(cat "$ef" 2>/dev/null)"
  shopt -s nocasematch
  case "$blob" in
    *quota*|*"rate limit"*|*"resource exhausted"*)
      shopt -u nocasematch; ens_signal QUOTA_EXHAUSTED "quota/rate limit" "$ep"; echo 10; return ;;
    *unauthenticated*|*unauthorized*|*"sign in"*|*"please authenticate"*|*reauth*)
      shopt -u nocasematch; ens_signal AUTH_REQUIRED "not authenticated" "$ep"; echo 11; return ;;
    *"timed out"*|*"deadline exceeded"*)
      shopt -u nocasematch; ens_signal TIMEOUT "deadline exceeded" "$ep"; echo 12; return ;;
  esac
  shopt -u nocasematch
  ens_signal FAILED "exit $rc" "$ep"; echo 2
}
