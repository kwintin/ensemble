# shellcheck shell=bash
ens_endpoint_field() { # ROSTER ID FIELD
  python3 - "$1" "$2" "$3" <<'PY'
import json,sys
r,eid,field=sys.argv[1],sys.argv[2],sys.argv[3]
try:
    d=json.load(open(r, encoding="utf-8"))
except (OSError, json.JSONDecodeError) as ex:
    sys.stderr.write("roster: cannot read %s: %s\n" % (r, ex)); sys.exit(1)
if not isinstance(d, dict):
    sys.stderr.write("roster: malformed (expected a JSON object)\n"); sys.exit(1)
for e in (d.get("endpoints") or []):
    if e.get("id")==eid:
        v=e.get(field,""); print(v if not isinstance(v,(list,dict)) else json.dumps(v)); break
PY
}
ens_endpoints_enabled() { # ROSTER
  python3 - "$1" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError) as ex:
    sys.stderr.write("roster: cannot read %s: %s\n" % (sys.argv[1], ex)); sys.exit(1)
if not isinstance(d, dict):
    sys.stderr.write("roster: malformed (expected a JSON object)\n"); sys.exit(1)
for e in (d.get("endpoints") or []):
    if e.get("enabled"):
        i=e.get("id")
        if i: print(i)
PY
}
ens_family_of() { ens_endpoint_field "$1" "$2" family; }
