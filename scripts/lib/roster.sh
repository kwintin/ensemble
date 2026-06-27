# shellcheck shell=bash
ens_endpoint_field() { # ROSTER ID FIELD
  python3 - "$1" "$2" "$3" <<'PY'
import json,sys
r,eid,field=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(r))
for e in d.get("endpoints",[]):
    if e.get("id")==eid:
        v=e.get(field,""); print(v if not isinstance(v,(list,dict)) else json.dumps(v)); break
PY
}
ens_endpoints_enabled() { # ROSTER
  python3 - "$1" <<'PY'
import json,sys
for e in json.load(open(sys.argv[1])).get("endpoints",[]):
    if e.get("enabled"): print(e["id"])
PY
}
ens_family_of() { ens_endpoint_field "$1" "$2" family; }
