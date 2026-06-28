#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
ROSTER="${ENSEMBLE_ROSTER:-$ROOT/roster.json}"
source "$SCRIPTS/lib/roster.sh"

die() { echo "ens-review: $*" >&2; exit 1; }

PROMPT_FILE=""; SUBSET=""; STDIN_TMP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reviewers) SUBSET="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    -) PROMPT_FILE="$(mktemp)"; cat > "$PROMPT_FILE"; STDIN_TMP="$PROMPT_FILE"; shift ;;
    *) die "unknown arg '$1'" ;;
  esac
done
[ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || die "need --prompt-file or '-'"

# select reviewers
if [ -n "$SUBSET" ]; then
  IFS=',' read -r -a REVIEWERS <<< "$SUBSET"
else
  mapfile -t REVIEWERS < <(ens_reviewers "$ROSTER")
fi
[ "${#REVIEWERS[@]}" -gt 0 ] || die "no reviewers selected"

# test-only: parse ENS_TEST_MODES "id=mode,id=mode" -> per-endpoint STUB_MODE
test_mode_for() { # ENDPOINT -> mode or empty
  local ep="$1" pair
  local -a _pairs
  [ -n "${ENS_TEST_MODES:-}" ] || return 0
  IFS=',' read -r -a _pairs <<< "$ENS_TEST_MODES"
  for pair in "${_pairs[@]}"; do
    case "$pair" in "$ep="*) echo "${pair#*=}"; return 0 ;; esac
  done
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; [ -n "$STDIN_TMP" ] && rm -f "$STDIN_TMP"' EXIT

# dispatch each reviewer in the background
# NOTE: endpoint ids are used as temp-file names; the roster schema is name@adapter (no '/').
for ep in "${REVIEWERS[@]}"; do
  mode="$(test_mode_for "$ep")"
  ( STUB_MODE="${mode:-ok}" "$SCRIPTS/model-cli.sh" review --endpoint "$ep" --prompt-file "$PROMPT_FILE" \
      >"$WORK/$ep.out" 2>"$WORK/$ep.err"; echo $? >"$WORK/$ep.rc" ) &
done
wait

python3 - "$WORK" "$ROSTER" "${REVIEWERS[@]}" <<'PY'
import json,os,sys
work,roster=sys.argv[1],sys.argv[2]; eps=sys.argv[3:]
rd=json.load(open(roster, encoding="utf-8"))
fam={e["id"]:e.get("family") for e in (rd.get("endpoints") or []) if isinstance(e,dict) and e.get("id")}
REASON={2:"failed",3:"empty",10:"quota",11:"auth",12:"timeout",13:"missing"}
reviewers=[]
for ep in eps:
    p=os.path.join(work,ep)
    rc=int(open(p+".rc").read().strip()) if os.path.exists(p+".rc") else 1
    rec={"endpoint":ep,"family":fam.get(ep),"status":"ok","reason":None,"verdict":None,"findings":[]}
    if rc==0:
        try:
            v=json.load(open(p+".out", encoding="utf-8"))
            rec["verdict"]=v.get("verdict"); rec["findings"]=v.get("findings") or []
        except Exception:
            rec["status"]="degraded"; rec["reason"]="unparseable"
    else:
        rec["status"]="degraded"; rec["reason"]=REASON.get(rc,"failed")
    reviewers.append(rec)
print(json.dumps({"reviewers":reviewers}, indent=2))
PY
