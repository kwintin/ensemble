#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
die() { echo "ens-council: $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Council mode (design spec §6.2): a de-biased two-round review.
#   ROUND 1   normal multi-model review (ens-review.sh)
#   ANONYMIZE shuffle the round-1 reviews, relabel A.., strip model identity
#   PEER ROUND re-dispatch the SAME reviewers with the anonymized set + a
#             cross-critique instruction ("what did they miss / get wrong?")
#   (CHAIRMAN  — the human/Claude synthesizes by judgment; that is the skill's
#               job, not this script's)
# This script is the mechanical orchestrator; it emits one JSON object
# {mode, anon_labels, round1, round2} for the chairman to read. It performs NO
# isolation itself — each round delegates to ens-review.sh (disposable worktree).
# Exit: 0 ok · 4 cannot convene / below quorum · 5 read-only violation (propagated).
# ----------------------------------------------------------------------------

PROMPT_FILE=""; SUBSET=""; STDIN_TMP=""
WORK="$(mktemp -d)" || die "mktemp -d failed"
[ -n "$WORK" ] && [ -d "$WORK" ] || die "could not create work dir"
trap 'rm -rf "$WORK"; [ -n "$STDIN_TMP" ] && rm -f "$STDIN_TMP"' EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --reviewers) SUBSET="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    -) PROMPT_FILE="$(mktemp)"; cat > "$PROMPT_FILE"; STDIN_TMP="$PROMPT_FILE"; shift ;;
    *) die "unknown arg '$1'" ;;
  esac
done
[ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || die "need --prompt-file or '-'"
_d="$(cd "$(dirname "$PROMPT_FILE")" 2>/dev/null && pwd)" || die "cannot resolve prompt-file dir"
PROMPT_FILE="$_d/$(basename "$PROMPT_FILE")"

REV_ARGS=()
[ -n "$SUBSET" ] && REV_ARGS=(--reviewers "$SUBSET")

emit_partial() { # R1JSON NOTE  -> council JSON with round2 null
  python3 - "$1" "$2" <<'PY'
import json,sys
r1=json.load(open(sys.argv[1]))
print(json.dumps({"mode":"council","anon_labels":{},"round1":r1,"round2":None,"note":sys.argv[2]}, indent=2))
PY
}

# ---- ROUND 1 ----
R1="$WORK/r1.json"
"$SCRIPTS/ens-review.sh" ${REV_ARGS[@]+"${REV_ARGS[@]}"} --prompt-file "$PROMPT_FILE" > "$R1"; r1rc=$?
[ "$r1rc" -eq 5 ] && { cat "$R1"; exit 5; }                       # read-only violation
if [ "$r1rc" -ne 0 ] && [ "$r1rc" -ne 4 ]; then cat "$R1" 2>/dev/null; exit "$r1rc"; fi

# ---- ANONYMIZE: render each OK reviewer, identity-strip (sort by content hash),
#      relabel A.., emit the peer block + the OK-endpoint list for round 2 ----
PEER="$WORK/peer.txt"; OKEPS="$WORK/okeps.txt"; LABELS="$WORK/labels.json"
nok="$(python3 - "$R1" "$PEER" "$OKEPS" "$LABELS" <<'PY'
import json,sys,hashlib
r1=json.load(open(sys.argv[1]))
ok=[r for r in r1.get("reviewers",[]) if r.get("status")=="ok"]
def render(r):
    parts=["Verdict: %s" % (r.get("verdict") or "UNKNOWN")]
    for f in (r.get("findings") or []):
        if isinstance(f,dict):
            parts.append("- %s:%s [%s] %s" % (f.get("file","?"),f.get("line","?"),
                                              f.get("severity","?"),f.get("issue","")))
    rv=(r.get("review") or "").strip()
    if rv and not rv.lstrip().startswith("{"):   # prose (sentinel reviewers), not codex JSON
        parts.append(rv)
    return "\n".join(parts)
items=[(r["endpoint"], render(r)) for r in ok]
# strip identity: order by content hash so label A.. does not track roster/model order
items.sort(key=lambda t: hashlib.sha256(t[1].encode("utf-8","replace")).hexdigest())
labels={}; blocks=[]
for i,(ep,txt) in enumerate(items):
    lab=chr(ord("A")+i) if i<26 else "R%d"%i
    labels[lab]=ep
    blocks.append("===== REVIEW %s =====\n%s" % (lab, txt))
open(sys.argv[2],"w",encoding="utf-8").write("\n\n".join(blocks))
open(sys.argv[3],"w",encoding="utf-8").write(",".join(ep for ep,_ in items))
json.dump(labels, open(sys.argv[4],"w",encoding="utf-8"))
print(len(items))
PY
)"

# a council needs at least two reviewers to cross-examine
if [ "${nok:-0}" -lt 2 ]; then
  emit_partial "$R1" "fewer than 2 OK reviewers in round 1; council not convened"
  exit 4
fi

# ---- build the peer prompt: original artifact + anonymized peer reviews + task ----
PEERPROMPT="$WORK/peerprompt.txt"
{
  cat "$PROMPT_FILE"
  printf '\n\n--- PEER REVIEWS (anonymized) ---\n'
  printf 'Below are %s independent reviews (labelled A..) of the SAME artifact above.\n\n' "$nok"
  cat "$PEER"
  printf '\n\n--- YOUR TASK ---\n'
  printf 'These peers reviewed the same artifact. Identify what they MISSED and where they are WRONG, citing the artifact. Then give YOUR final verdict. Do not defer to the majority — a correct minority is still correct.\n'
} > "$PEERPROMPT"

# ---- ROUND 2 (peer round): the same round-1 OK reviewers ----
R2="$WORK/r2.json"
"$SCRIPTS/ens-review.sh" --reviewers "$(cat "$OKEPS")" --prompt-file "$PEERPROMPT" > "$R2"; r2rc=$?
[ "$r2rc" -eq 5 ] && { cat "$R2"; exit 5; }

# ---- EMIT both rounds + the de-anonymization map ----
python3 - "$R1" "$R2" "$LABELS" <<'PY'
import json,sys
print(json.dumps({"mode":"council",
                  "anon_labels":json.load(open(sys.argv[3])),
                  "round1":json.load(open(sys.argv[1])),
                  "round2":json.load(open(sys.argv[2]))}, indent=2))
PY
exit "$r2rc"
