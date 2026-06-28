# shellcheck shell=bash
# Normalize raw reviewer output -> {endpoint,verdict,findings[],raw}.
ens_normalize_verdict() { # ENDPOINT MODE RAW_FILE
  python3 - "$1" "$2" "$3" <<'PY'
import json,re,sys
ep,mode,raw_path=sys.argv[1],sys.argv[2],sys.argv[3]
raw=open(raw_path, errors='replace').read()
verdict="ERROR"; findings=[]
if mode=="json":
    try:
        o=json.loads(raw)
        verdict=str(o.get("verdict","ERROR")).upper()
        findings=o.get("findings",[])
        if not isinstance(findings, list): findings=[]
    except Exception:
        verdict="ERROR"
else:  # sentinel
    m=re.search(r"===VERDICT===\s*(\w+)", raw)
    if m: verdict=m.group(1).upper()
if verdict not in ("APPROVED","CHANGES","ERROR"): verdict="ERROR"
print(json.dumps({"endpoint":ep,"verdict":verdict,"findings":findings,"raw":raw}, indent=2))
PY
}
