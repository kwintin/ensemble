# shellcheck shell=bash
# Validated, configurable size caps for the free-text fields the engines carry into
# their JSON output (reviewer prose, executor stderr).
#
# Why a cap exists at all: these fields flow straight into the conductor's context,
# and an unbounded one can dump a very large payload there. Why it must be tunable
# AND reported: a silent cap is worse than a large one. For a sentinel reviewer the
# prose IS the review — there is no findings[] to fall back on — so a cap that trims
# it without saying so discards real findings and reads as if they were never made.
# Every caller of ens_cap therefore also emits a *_truncated / *_chars pair next to
# the text it trimmed.
#
# ens_cap VARNAME DEFAULT [WHO] -> echoes the validated cap.
#   unset/empty  -> DEFAULT
#   non-numeric or negative (both match *[!0-9]*) -> DEFAULT, with a warning on stderr
#   0            -> uncapped (callers treat 0 as "no limit")

[ -n "${_ENS_CAP_LIB:-}" ] && return 0
_ENS_CAP_LIB=1

ens_cap() { # VARNAME DEFAULT [WHO]
  local name="$1" def="$2" who="${3:-ensemble}" val
  val="${!name:-}"
  [ -n "$val" ] || { printf '%s' "$def"; return 0; }
  case "$val" in
    ''|*[!0-9]*)
      printf '%s: warning: ignoring invalid %s=%s (want a non-negative integer, 0 = uncapped); using %s\n' \
        "$who" "$name" "$val" "$def" >&2
      printf '%s' "$def"; return 0 ;;
  esac
  printf '%s' "$val"
}
