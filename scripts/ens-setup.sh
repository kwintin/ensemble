#!/usr/bin/env bash
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS="$ROOT/scripts"
DEFAULTS="${ENS_MODEL_DEFAULTS:-$ROOT/data/model-defaults.json}"
source "$SCRIPTS/lib/timeout.sh"
source "$SCRIPTS/lib/adapter_common.sh"
die() { echo "ens-setup: $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Setup-wizard helpers (design spec §5). The wizard ENGINE is the ensemble-setup
# skill (it asks the questions); these subcommands are the deterministic parts:
#   detect    per-transport health + model list (for the picker)
#   family    normalize a model id -> canonical family (diversity is by family)
#   defaults  seeded strengths + latency for a model id
#   validate  sanity-check a roster.json the wizard wrote
# ----------------------------------------------------------------------------

ADAPTERS="codex agy grok opencode kilo vibe"

sub="${1:-}"; shift || true
case "$sub" in detect|family|defaults|validate) : ;; *) die "usage: ens-setup.sh detect|family|defaults|validate ..." ;; esac

# ============================ detect ============================
if [ "$sub" = "detect" ]; then
  WORK="$(mktemp -d)" || die "mktemp failed"
  trap 'rm -rf "$WORK"' EXIT
  for a in $ADAPTERS; do
    [ -f "$SCRIPTS/adapters/$a.sh" ] || continue
    ( source "$SCRIPTS/adapters/$a.sh"
      h="$("${a}_health" 2>/dev/null || echo missing)"
      ec=0; declare -F "${a}_run" >/dev/null 2>&1 && ec=1
      printf '%s\t%s\n' "$h" "$ec" > "$WORK/$a.meta"
      if [ "$h" = ok ]; then "${a}_list_models" 2>/dev/null | head -200 > "$WORK/$a.models"; else : > "$WORK/$a.models"; fi
    )
  done
  python3 - "$WORK" $ADAPTERS <<'PY'
import json,os,sys
work=sys.argv[1]; adapters=sys.argv[2:]
out=[]
for a in adapters:
    mp=os.path.join(work,a+".meta")
    if not os.path.exists(mp): continue
    meta=open(mp,encoding="utf-8",errors="replace").read().strip()
    h,ec=(meta.split("\t")+["0"])[:2] if "\t" in meta else (meta or "missing","0")
    models=[m for m in open(os.path.join(work,a+".models"),encoding="utf-8",errors="replace").read().splitlines() if m.strip()]
    out.append({"adapter":a,"health":h,"executor_capable":ec=="1",
                "structured_output":"json" if a=="codex" else "sentinel",
                "default_role":"reviewer" if not (ec=="1") else "both",
                "model_count":len(models),"models":models})
print(json.dumps({"adapters":out}, indent=2))
PY
  exit 0
fi

# ============================ family ============================
if [ "$sub" = "family" ]; then
  [ $# -ge 1 ] || die "usage: ens-setup.sh family <model-id>"
  python3 - "$DEFAULTS" "$1" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: d={}
m=sys.argv[2].lower()
vf=d.get("vendor_families",{}) if isinstance(d,dict) else {}
# longest matching vendor token wins (so "deepseek" beats a stray "seek")
hit=""
for k in sorted(vf,key=len,reverse=True):
    if k in m: hit=vf[k]; break
print(hit or "unknown")
PY
  exit 0
fi

# ============================ defaults ============================
if [ "$sub" = "defaults" ]; then
  [ $# -ge 1 ] || die "usage: ens-setup.sh defaults <model-id>"
  python3 - "$DEFAULTS" "$1" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: d={}
m=sys.argv[2].lower()
for row in (d.get("model_strengths") or []):
    if isinstance(row,dict) and row.get("match","") in m:
        print(json.dumps({"strengths":row.get("strengths",[]),"latency_tier":row.get("latency","medium")})); break
else:
    print(json.dumps({"strengths":[],"latency_tier":"medium"}))
PY
  exit 0
fi

# ============================ validate ============================
if [ "$sub" = "validate" ]; then
  [ $# -ge 1 ] && [ -f "$1" ] || die "usage: ens-setup.sh validate <roster.json>"
  python3 - "$SCRIPTS" "$1" <<'PY'; rc=$?
import json,os,sys
scripts,path=sys.argv[1],sys.argv[2]; errs=[]
try: d=json.load(open(path,encoding="utf-8"))
except Exception as e: print("  - not valid JSON: %s"%e); sys.exit(1)
if not isinstance(d,dict): print("  - top level must be an object"); sys.exit(1)
eps=d.get("endpoints")
if not isinstance(eps,list) or not eps: print("  - 'endpoints' must be a non-empty list"); sys.exit(1)
seen=set()
for i,e in enumerate(eps):
    if not isinstance(e,dict): errs.append("endpoint %d not an object"%i); continue
    eid=e.get("id"); ad=e.get("adapter")
    if not eid: errs.append("endpoint %d missing id"%i); continue
    if eid in seen: errs.append("duplicate id '%s'"%eid)
    seen.add(eid)
    if not ad or not os.path.isfile(os.path.join(scripts,"adapters",str(ad)+".sh")): errs.append("%s: unknown adapter '%s'"%(eid,ad))
    if e.get("role") not in ("reviewer","executor","both"): errs.append("%s: role must be reviewer|executor|both"%eid)
    if e.get("structured_output") not in ("json","sentinel"): errs.append("%s: structured_output must be json|sentinel"%eid)
    if e.get("effort") not in ("minimal","low","medium","high","xhigh"): errs.append("%s: invalid effort"%eid)
    if not e.get("family"): errs.append("%s: missing family (diversity needs it)"%eid)
    if not isinstance(e.get("enabled"),bool): errs.append("%s: enabled must be true/false"%eid)
    if e.get("role") in ("executor","both"):
        ec = ad != "vibe"
        if not ec: errs.append("%s: adapter '%s' is not executor-capable (set role: reviewer)"%(eid,ad))
mq=d.get("min_quorum",2)
if not (isinstance(mq,int) and not isinstance(mq,bool) and mq>=1): errs.append("min_quorum must be an integer >= 1")
# diversity: warn (not error) on duplicate enabled families
fams={}
for e in eps:
    if isinstance(e,dict) and e.get("enabled") and e.get("family"):
        fams.setdefault(e["family"],[]).append(e.get("id"))
dups={f:ids for f,ids in fams.items() if len(ids)>1}
if errs:
    [print("  -",x) for x in errs]; sys.exit(1)
if dups:
    for f,ids in dups.items(): print("  note: family '%s' has >1 enabled endpoint (%s) — counts once toward quorum"%(f,", ".join(ids)))
print("roster valid: %d endpoints, %d distinct enabled families"%(len(eps),len(fams)))
PY
  exit "$rc"
fi
