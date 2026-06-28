# shellcheck shell=bash
# codex transport adapter. Requires lib/timeout.sh sourced (ens_run_timeout).
# NOTE: real-codex flag interplay (--output-schema + -o on `exec`) is verified in
# Task 10 (Tier-2). The stub emulates the contract for Tier-1.

_codex_schema_file() {  # emits a temp JSON-Schema file path for the verdict shape
  # NOTE: OpenAI structured-output requires additionalProperties:false and every
  # property key listed in required at every object level (real-codex validated in Task 10).
  local f; f="$(mktemp)"
  cat >"$f" <<'J'
{"type":"object","additionalProperties":false,"required":["verdict","findings"],"properties":{
  "verdict":{"type":"string","enum":["APPROVED","CHANGES"]},
  "findings":{"type":"array","items":{"type":"object","additionalProperties":false,
    "required":["file","line","severity","issue"],"properties":{
    "file":{"type":"string"},"line":{"type":"integer"},
    "severity":{"type":"string"},"issue":{"type":"string"}}}}}}
J
  echo "$f"
}

codex_review() { # ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE
  local ep="$1" model="$2" eff="$3" pf="$4" of="$5"
  local schema; schema="$(_codex_schema_file)"
  local prompt; prompt="$(cat "$pf")"
  local _e_was_set; [[ $- == *e* ]] && _e_was_set=1 || _e_was_set=0
  set +e
  ens_run_timeout 600 -- codex exec \
    --dangerously-bypass-approvals-and-sandbox --ephemeral \
    -c "model_reasoning_effort=$eff" -m "$model" \
    --output-schema "$schema" -o "$of" \
    "$prompt" </dev/null >/dev/null
  local rc=$?
  [ "$_e_was_set" -eq 1 ] && set -e || true
  rm -f "$schema"
  return $rc
}

codex_health() { # -> ok | auth | missing
  command -v codex >/dev/null 2>&1 || { echo missing; return 0; }
  local j; j="$(ens_run_timeout 20 -- codex doctor --json 2>/dev/null)"
  # Stub JSON (Tier-1): {"auth":"ok"}.
  # Real doctor JSON: checks["auth.credentials"]["status"] == "ok".
  # Support both via python3 parse; default to "auth" on any parse failure.
  local auth_ok; auth_ok="$(printf '%s' "$j" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    # Real format
    if isinstance(d, dict) and "checks" in d:
        c = d["checks"].get("auth.credentials", {})
        print("ok" if c.get("status") == "ok" else "auth"); sys.exit(0)
    # Stub format
    if d.get("auth") == "ok":
        print("ok"); sys.exit(0)
    print("auth")
except Exception:
    print("auth")
' 2>/dev/null)"
  echo "${auth_ok:-auth}"
}

codex_list_models() { # -> model ids, one per line (best-effort)
  command -v codex >/dev/null 2>&1 || return 0
  local init list
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"ensemble-setup","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}'
  list='{"jsonrpc":"2.0","id":2,"method":"model/list","params":{"includeHidden":false}}'
  { printf '%s\n' "$init"; sleep 1; printf '%s\n' "$list"; sleep 1; } \
    | ens_run_timeout 25 -- codex app-server --stdio 2>/dev/null \
    | python3 -c '
import sys,json
for ln in sys.stdin:
    ln=ln.strip()
    if not ln: continue
    try: o=json.loads(ln)
    except: continue
    if o.get("id")==2 and "result" in o:
        for m in o["result"].get("data",[]): print(m.get("id",""))'
}
