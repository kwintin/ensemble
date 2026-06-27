# shellcheck shell=bash
# codex transport adapter. Requires lib/timeout.sh sourced (ens_run_timeout).
# NOTE: real-codex flag interplay (--output-schema + -o on `exec`) is verified in
# Task 10 (Tier-2). The stub emulates the contract for Tier-1.

_codex_schema_file() {  # emits a temp JSON-Schema file path for the verdict shape
  local f; f="$(mktemp)"
  cat >"$f" <<'J'
{"type":"object","required":["verdict"],"properties":{
  "verdict":{"type":"string","enum":["APPROVED","CHANGES"]},
  "findings":{"type":"array","items":{"type":"object","properties":{
    "file":{"type":"string"},"line":{"type":"integer"},
    "severity":{"type":"string"},"issue":{"type":"string"}}}}}}
J
  echo "$f"
}

codex_review() { # ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE
  local ep="$1" model="$2" eff="$3" pf="$4" of="$5"
  local schema; schema="$(_codex_schema_file)"
  local prompt; prompt="$(cat "$pf")"
  set +e
  ens_run_timeout 600 -- codex exec \
    --sandbox read-only --ephemeral \
    -c "model_reasoning_effort=$eff" -m "$model" \
    --output-schema "$schema" -o "$of" \
    "$prompt"
  local rc=$?
  set -e
  rm -f "$schema"
  return $rc
}

codex_health() { # -> ok | auth | missing
  command -v codex >/dev/null 2>&1 || { echo missing; return 0; }
  local j; j="$(ens_run_timeout 20 -- codex doctor --json 2>/dev/null)"
  case "$j" in *'"auth":"ok"'*) echo ok ;; *) echo auth ;; esac
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
