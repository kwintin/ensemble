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
#   idfor     a clean, engine-safe endpoint id for a (model, adapter)
#   defaults  seeded strengths + latency for a model id (resolved via family)
#   validate  sanity-check a roster.json the wizard wrote
# ----------------------------------------------------------------------------

ADAPTERS="codex agy grok opencode kilo vibe"

sub="${1:-}"; shift || true
case "$sub" in detect|family|idfor|defaults|validate) : ;; *) die "usage: ens-setup.sh detect|family|idfor|defaults|validate ..." ;; esac

# ============================ detect ============================
if [ "$sub" = "detect" ]; then
  WORK="$(mktemp -d)" || die "mktemp failed"
  trap 'rm -rf "$WORK"' EXIT
  for a in $ADAPTERS; do
    [ -f "$SCRIPTS/adapters/$a.sh" ] || continue
    printf 'error\t0\n' > "$WORK/$a.meta"; : > "$WORK/$a.models"   # fallback if the subshell dies (broken adapter)
    ( source "$SCRIPTS/adapters/$a.sh"
      h="$("${a}_health" 2>/dev/null || echo missing)"
      ec=0; declare -F "${a}_run" >/dev/null 2>&1 && ec=1
      printf '%s\t%s\n' "$h" "$ec" > "$WORK/$a.meta"
      if [ "$h" = ok ]; then ens_run_timeout 30 -- bash -c "source '$SCRIPTS/adapters/$a.sh'; ${a}_list_models" 2>/dev/null | head -200 > "$WORK/$a.models"; fi
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
    h,ec=(meta.split("\t")+["0"])[:2] if "\t" in meta else (meta or "error","0")
    models=[m for m in open(os.path.join(work,a+".models"),encoding="utf-8",errors="replace").read().splitlines() if m.strip()]
    out.append({"adapter":a,"health":h,"executor_capable":ec=="1",
                "structured_output":"json" if a=="codex" else "sentinel",
                "default_role":"both" if ec=="1" else "reviewer",
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
# longest token first, then alphabetical -> deterministic tie-break
hit=""
for k in sorted(vf, key=lambda x:(-len(x), x)):
    if k in m: hit=vf[k]; break
print(hit or "unknown")
PY
  exit 0
fi

# ============================ idfor ============================
if [ "$sub" = "idfor" ]; then
  [ $# -ge 2 ] || die "usage: ens-setup.sh idfor <model-id> <adapter>"
  python3 - "$1" "$2" <<'PY'
import re,sys
model,adapter=sys.argv[1],sys.argv[2]
seg=model.rsplit("/",1)[-1].lower()                 # last path segment of a router id
seg=re.sub(r"[^a-z0-9._-]+","-",seg).strip("-._")    # engine-safe charset (^[A-Za-z0-9._@-]+$ after @adapter)
seg=re.sub(r"-{2,}","-",seg) or "model"
ad=re.sub(r"[^a-z0-9_-]+","-",adapter.lower()).strip("-") or "adapter"
print("%s@%s" % (seg, ad))
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
vf=d.get("vendor_families",{}) if isinstance(d,dict) else {}
fam=""
for k in sorted(vf, key=lambda x:(-len(x), x)):
    if k in m: fam=vf[k]; break
fs=(d.get("family_strengths") or {}).get(fam, {})
print(json.dumps({"family":fam or "unknown",
                  "strengths":fs.get("strengths",[]),
                  "latency_tier":fs.get("latency","medium")}))
PY
  exit 0
fi

# ============================ validate ============================
if [ "$sub" = "validate" ]; then
  [ $# -ge 1 ] && [ -f "$1" ] || die "usage: ens-setup.sh validate <roster.json>"
  python3 - "$SCRIPTS" "$1" <<'PY'; rc=$?
import json,os,re,sys
scripts,path=sys.argv[1],sys.argv[2]; errs=[]
ID_RE=re.compile(r'^[A-Za-z0-9._@-]+$')          # engine-safe endpoint id (no slashes/spaces)
MODEL_RE=re.compile(r'^[A-Za-z0-9 ()._/+-]+$')    # matches model-cli's model sanity check
def has_run(ad):
    p=os.path.join(scripts,"adapters",str(ad)+".sh")
    try: return re.search(r'(?m)^%s_run\s*\(\)' % re.escape(str(ad)), open(p,encoding="utf-8").read()) is not None
    except Exception: return False
try: d=json.load(open(path,encoding="utf-8"))
except Exception as e: print("  - not valid JSON: %s"%e); sys.exit(1)
if not isinstance(d,dict): print("  - top level must be an object"); sys.exit(1)
eps=d.get("endpoints")
if not isinstance(eps,list) or not eps: print("  - 'endpoints' must be a non-empty list"); sys.exit(1)
ids=set()
for i,e in enumerate(eps):
    if not isinstance(e,dict): errs.append("endpoint %d not an object"%i); continue
    eid=e.get("id"); ad=e.get("adapter")
    if not eid: errs.append("endpoint %d missing id"%i); continue
    if not ID_RE.match(str(eid)): errs.append("%s: id has chars the engines reject (use an engine-safe id like 'model-token@adapter')"%eid)
    if eid in ids: errs.append("duplicate id '%s'"%eid)
    ids.add(eid)
    if not ad or not os.path.isfile(os.path.join(scripts,"adapters",str(ad)+".sh")): errs.append("%s: unknown adapter '%s'"%(eid,ad)); continue
    mdl=e.get("model")
    if not mdl or not isinstance(mdl,str) or not MODEL_RE.match(mdl): errs.append("%s: missing or invalid model '%s'"%(eid,mdl))
    if e.get("role") not in ("reviewer","executor","both"): errs.append("%s: role must be reviewer|executor|both"%eid)
    if e.get("structured_output") != ("json" if ad=="codex" else "sentinel"):
        errs.append("%s: structured_output must be '%s' for adapter '%s'"%(eid,"json" if ad=="codex" else "sentinel",ad))
    if e.get("effort") not in ("minimal","low","medium","high","xhigh"): errs.append("%s: invalid effort"%eid)
    if not e.get("family"): errs.append("%s: missing family (diversity needs it)"%eid)
    if not isinstance(e.get("enabled"),bool): errs.append("%s: enabled must be true/false"%eid)
    if e.get("role") in ("executor","both") and not has_run(ad):
        errs.append("%s: adapter '%s' is not executor-capable (no %s_run) — set role: reviewer"%(eid,ad,ad))
mq=d.get("min_quorum",2)
if not (isinstance(mq,int) and not isinstance(mq,bool) and mq>=1): errs.append("min_quorum must be an integer >= 1")
rd=d.get("reviewers_default")
if rd is not None:
    if not isinstance(rd,list) or not all(isinstance(x,str) for x in rd): errs.append("reviewers_default must be a list of endpoint ids")
    else:
        for x in rd:
            if x not in ids: errs.append("reviewers_default references unknown endpoint '%s'"%x)
fams={}
for e in eps:
    if isinstance(e,dict) and e.get("enabled") and e.get("family"): fams.setdefault(e["family"],[]).append(e.get("id"))
if errs:
    [print("  -",x) for x in errs]; sys.exit(1)
for f,xs in fams.items():
    if len(xs)>1: print("  note: family '%s' has >1 enabled endpoint (%s) — counts once toward quorum"%(f,", ".join(xs)))
print("roster valid: %d endpoints, %d distinct enabled families"%(len(eps),len(fams)))
PY
  exit "$rc"
fi
