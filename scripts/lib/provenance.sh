# shellcheck shell=bash
# Provenance & transparency logging — the SOLE emitter of the ▶ (dispatch) and ◀
# (result) lines. Emits to stderr. See docs/specs/2026-06-29-provenance-logging-design.md.
# Self-contained: ens_endpoint_fields does its own roster read, so this file does
# not require lib/roster.sh, though engines that use it also source roster.sh.

# ENSEMBLE_PROVENANCE: default on; case-insensitive 0/off/false/no/disabled silences.
_ens_provenance_on() {
  local v; v="$(printf '%s' "${ENSEMBLE_PROVENANCE-1}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in 0|off|false|no|disabled) return 1 ;; *) return 0 ;; esac
}

# Resolve several endpoint fields in ONE python spawn (ens_endpoint_field is
# one-field-per-spawn; three named calls would be three spawns -> ~576 on the
# calibrate hot path). Prints one value per requested field, in order.
ens_endpoint_fields() { # ENDPOINT ROSTER FIELD...
  local ep="$1" roster="$2"; shift 2
  python3 - "$roster" "$ep" "$@" <<'PY'
import json,sys
roster,eid=sys.argv[1],sys.argv[2]; fields=sys.argv[3:]
try:
    d=json.load(open(roster,encoding="utf-8"))
    if not isinstance(d,dict): d={}
except Exception:
    d={}
e=next((x for x in (d.get("endpoints") or []) if isinstance(x,dict) and x.get("id")==eid), {})
for f in fields:
    v=e.get(f,"")
    print(v if not isinstance(v,(list,dict)) else json.dumps(v))
PY
}

# Collapse CR/LF/TAB in an assembled line to single spaces, so no interpolated
# value (reason/detail/roster field) can inject a newline and fabricate a second
# provenance line in the log. Defense-in-depth: real inputs are already constrained
# (endpoint ids are validated, model/family come from operator config), but this
# makes the no-log-injection property self-evident. Uses printf -v + parameter
# expansion only — no subshell, bash 3.2-safe (macOS).
_ens_prov_emit() { # FORMAT ARG...   (prints the rendered, sanitized line to stderr)
  local _fmt="$1"; shift
  local _line; printf -v _line "$_fmt" "$@"
  _line=${_line//$'\n'/ }; _line=${_line//$'\r'/ }; _line=${_line//$'\t'/ }
  printf '%s\n' "$_line" >&2
}

# ▶ dispatch line. cli=<adapter>; a missing field renders "?".
ens_provenance() { # OP ENDPOINT ROSTER [reason]
  _ens_provenance_on || return 0
  local op="$1" ep="$2" roster="$3" reason="${4:-}" cli model family
  { read -r cli; read -r model; read -r family; } < <(ens_endpoint_fields "$ep" "$roster" adapter model family)
  _ens_prov_emit '▶ %s %s · cli=%s · model=%s · family=%s%s' \
    "$op" "$ep" "${cli:-?}" "${model:-?}" "${family:-?}" "${reason:+ · $reason}"
}

# ◀ result line. Field-free; optional trailing detail slot.
ens_provenance_result() { # OP ENDPOINT OUTCOME [detail]
  _ens_provenance_on || return 0
  local op="$1" ep="$2" outcome="$3" detail="${4:-}"
  _ens_prov_emit '◀ %s %s%s → %s' "$op" "$ep" "${detail:+ · $detail}" "$outcome"
}
