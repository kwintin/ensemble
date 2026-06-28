#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
die() { echo "ens-council: $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Council mode (design spec §6.2): a de-biased two-round review.
#   ROUND 1   normal multi-model review (ens-review.sh)
#   ANONYMIZE render each round-1 review, SCRUB self-identifying tokens, sort by
#             content hash (strip roster order), relabel A.., emit a de-anon map
#   PEER ROUND re-dispatch the SAME OK reviewers with the anonymized set + a
#             cross-critique instruction ("what did they miss / get wrong?")
#   (CHAIRMAN  — the human/Claude synthesizes by judgment; that is the skill's job)
# This script is the mechanical orchestrator; it always emits one JSON object
# {mode, anon_labels, round1, round2} for the chairman (round2 may be null when
# the council cannot convene). It performs NO isolation itself — each round
# delegates to ens-review.sh (disposable worktree).
# Exit: 0 ok · 4 cannot convene / below quorum · 5 read-only violation.
# ----------------------------------------------------------------------------

PROMPT_FILE=""; SUBSET=""; STDIN_TMP=""; WORK=""; _cleaned=0
cleanup() {
  [ "$_cleaned" = 1 ] && return 0
  _cleaned=1
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ -n "$STDIN_TMP" ] && rm -f "$STDIN_TMP"
  return 0
}
on_signal() { cleanup; trap - INT TERM EXIT; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM

WORK="$(mktemp -d)" || die "mktemp -d failed"
[ -n "$WORK" ] && [ -d "$WORK" ] || die "could not create work dir"

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

# council wrapper with round2:null (round 1 only) — robust to malformed round-1 JSON
emit_partial() { # R1FILE NOTE
  python3 - "$1" "$2" <<'PY'
import json,sys
try:
    r1=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception as e:
    r1={"error":"round-1 output unparseable: %s" % e}
print(json.dumps({"mode":"council","anon_labels":{},"round1":r1,"round2":None,"note":sys.argv[2]},indent=2))
PY
}

# ---- ROUND 1 ----
R1="$WORK/r1.json"
"$SCRIPTS/ens-review.sh" ${REV_ARGS[@]+"${REV_ARGS[@]}"} --prompt-file "$PROMPT_FILE" > "$R1"; r1rc=$?
if [ "$r1rc" -eq 5 ]; then emit_partial "$R1" "read-only violation in round 1; council not convened"; exit 5; fi
if [ "$r1rc" -ne 0 ] && [ "$r1rc" -ne 4 ]; then cat "$R1" 2>/dev/null; exit "$r1rc"; fi

# ---- ANONYMIZE: render OK reviewers, scrub identity, hash-sort, relabel A.. ----
PEER="$WORK/peer.txt"; OKEPS="$WORK/okeps.txt"; LABELS="$WORK/labels.json"
nok="$(python3 - "$R1" "$PEER" "$OKEPS" "$LABELS" <<'PY'
import json,sys,re,hashlib
r1=json.load(open(sys.argv[1],encoding="utf-8"))
reviewers=r1.get("reviewers",[])
ok=[r for r in reviewers if r.get("status")=="ok"]
# deny-list of self-identifying tokens (endpoint model/adapter, family, vendors).
# Match each FULL token as a word-boundary literal — do NOT split model ids into
# sub-tokens, or generic words like "medium"/"pro"/"flash" (from mistral-medium-3.5,
# deepseek-v4-pro, gemini-3.5-flash) would be scrubbed and corrupt e.g. [medium] severities.
phrases=set()
for r in reviewers:
    ep=r.get("endpoint") or ""
    if "@" in ep:
        m,a=ep.split("@",1); phrases.add(m); phrases.add(a)
    if r.get("family"): phrases.add(r["family"])
# curated vendor/model names — each is itself identifying, never a generic English word
phrases |= {"grok","vibe","codex","agy","opencode","kilo","gemini","mistral","deepseek",
            "glm","claude","gpt","openai","google","anthropic","xai","zai","z-ai","antigravity"}
phrases={p for p in (str(x).strip().lower() for x in phrases) if len(p)>=3}
SCRUB=re.compile(r"(?i)\b(%s)\b" % "|".join(re.escape(p) for p in sorted(phrases,key=len,reverse=True))) if phrases else None
def scrub(s): return SCRUB.sub("[reviewer]", s) if SCRUB else s
def is_json(s):
    try: json.loads(s); return True
    except Exception: return False
def render(r):
    parts=["Verdict: %s" % (r.get("verdict") or "UNKNOWN")]
    for f in (r.get("findings") or []):
        if isinstance(f,dict):
            parts.append("- %s:%s [%s] %s" % (f.get("file","?"),f.get("line","?"),
                                              f.get("severity","?"),f.get("issue","")))
    rv=(r.get("review") or "").strip()
    if rv and not is_json(rv):     # codex's review field is a JSON blob -> use findings instead
        rv=re.split(r"\n?===VERDICT===", rv)[0].strip()   # drop the trailing sentinel block
        if rv: parts.append(rv)
    return scrub("\n".join(parts))
items=[(r["endpoint"], render(r)) for r in ok]
# strip identity: order by content hash so label A.. does not track roster/model order
items.sort(key=lambda t: hashlib.sha256(t[1].encode("utf-8","replace")).hexdigest())
labels={}; blocks=[]
for i,(ep,txt) in enumerate(items):
    lab=chr(ord("A")+i) if i<26 else "R%d" % i
    labels[lab]=ep
    blocks.append("===== REVIEW %s =====\n%s" % (lab, txt))
open(sys.argv[2],"w",encoding="utf-8").write("\n\n".join(blocks))
open(sys.argv[3],"w",encoding="utf-8").write(",".join(ep for ep,_ in items))
json.dump(labels, open(sys.argv[4],"w",encoding="utf-8"))
print(len(items))
PY
)"; anonrc=$?
if [ "$anonrc" -ne 0 ]; then emit_partial "$R1" "could not anonymize round-1 reviews; council not convened"; exit 4; fi
if [ "${nok:-0}" -lt 2 ]; then emit_partial "$R1" "fewer than 2 OK reviewers in round 1; council not convened"; exit 4; fi

# ---- build the peer prompt: original artifact + anonymized peer reviews + task ----
PEERPROMPT="$WORK/peerprompt.txt"
{
  cat "$PROMPT_FILE"
  printf '\n\n--- PEER REVIEWS (anonymized) ---\n'
  printf 'Below are %s independent reviews (labelled A, B, C, ...) of the SAME artifact above.\n\n' "$nok"
  cat "$PEER"
  printf '\n\n--- YOUR TASK ---\n'
  printf 'These peers reviewed the same artifact. Identify what they MISSED and where they are WRONG, citing the artifact. Then give YOUR final verdict. Do not defer to the majority — a correct minority is still correct.\n'
} > "$PEERPROMPT"
# test/inspection hook: expose the anonymized peer block
[ -n "${ENS_COUNCIL_DEBUG_DIR:-}" ] && cp "$PEER" "$ENS_COUNCIL_DEBUG_DIR/peer.txt" 2>/dev/null || true

# ---- ROUND 2 (peer round): the same round-1 OK reviewers ----
R2="$WORK/r2.json"
"$SCRIPTS/ens-review.sh" --reviewers "$(cat "$OKEPS")" --prompt-file "$PEERPROMPT" > "$R2"; r2rc=$?
# unexpected (non-contract) exit -> propagate raw rather than mis-emit
if [ "$r2rc" -ne 0 ] && [ "$r2rc" -ne 4 ] && [ "$r2rc" -ne 5 ]; then cat "$R2" 2>/dev/null; exit "$r2rc"; fi

# ---- EMIT the council object (covers 0/4/5; round2 carries any read-only flag) ----
# Each field degrades to an error envelope rather than aborting, so the chairman
# always receives the wrapper (round-1 work is never discarded on a parse hiccup).
python3 - "$R1" "$R2" "$LABELS" <<'PY'
import json,sys
def load(p):
    try: return json.load(open(p,encoding="utf-8"))
    except Exception as e: return {"error":"unparseable: %s" % e}
print(json.dumps({"mode":"council","anon_labels":load(sys.argv[3]),
                  "round1":load(sys.argv[1]),"round2":load(sys.argv[2])}, indent=2))
PY
exit "$r2rc"
