# shellcheck shell=bash
# codex transport adapter. Requires lib/timeout.sh sourced (ens_run_timeout).
# NOTE: real-codex flag interplay (--output-schema + -o on `exec`) is verified in
# Task 10 (Tier-2). The stub emulates the contract for Tier-1.

# defensively source the shared lib (codex_run uses ens_digest_prompt) so the adapter
# works when sourced standalone (tests) as well as via model-cli.sh
[ -n "${_ENS_ADAPTER_COMMON:-}" ] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/adapter_common.sh"

_codex_clear_parent_env() {
  # Remove the direct launcher/data pointers inherited from an outer Ensemble host,
  # so a nested codex cannot resolve its way back to this installation.
  #
  # Probed against codex-cli 0.149.0: neither --ignore-user-config NOR clearing
  # CODEX_HOME suppresses codex's own plugin/skill discovery -- a child launched
  # either way still reports loaded plugins. Env scrubbing therefore cannot make
  # re-entry impossible on its own; the prompt-level single-agent guard below is
  # what stops a nested reviewer from dispatching Ensemble again, backed by
  # --sandbox read-only (review) and --ephemeral.
  #
  # CODEX_HOME is deliberately NOT unset (unlike the claude adapter, which has no
  # use for it): it is where codex finds its credentials, so dropping it would
  # break auth for anyone on a non-default CODEX_HOME while closing nothing.
  unset CLAUDECODE CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA \
    ENSEMBLE_PLUGIN_ROOT ENSEMBLE_DATA_DIR ENSEMBLE_ROSTER \
    PLUGIN_ROOT PLUGIN_DATA
}

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

_codex_single_agent_guard() { # MODE (review | executor)
  local mode="$1"
  if [ "$mode" = "review" ]; then
    cat <<'TXT'
You are ONE independent reviewer inside an outer Ensemble run. Complete this review yourself. Do not invoke Ensemble (including its skills, commands, or scripts), model CLIs, other agents, or subagents. Return only the structured review required by the supplied output schema.

--- REVIEW REQUEST ---
TXT
  else
    cat <<'TXT'
You are ONE independent executor inside an outer Ensemble run. Complete this delegated task yourself. Do not invoke Ensemble (including its skills, commands, or scripts), model CLIs, other agents, or subagents.

TXT
  fi
}

codex_review() { # ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE
  local _ep="$1" model="$2" eff="$3" pf="$4" of="$5"
  local schema; schema="$(_codex_schema_file)"
  local prompt_file; prompt_file="$(mktemp)"
  { _codex_single_agent_guard review; cat "$pf"; } >"$prompt_file"
  local _e_was_set; [[ $- == *e* ]] && _e_was_set=1 || _e_was_set=0
  set +e
  (
    _codex_clear_parent_env
    ens_run_timeout 600 -- codex exec \
      --ignore-user-config --sandbox read-only --ephemeral \
      -c "model_reasoning_effort=$eff" -m "$model" \
      --output-schema "$schema" -o "$of" \
      - <"$prompt_file" >/dev/null
  )
  local rc=$?
  [ "$_e_was_set" -eq 1 ] && set -e || true
  rm -f "$schema" "$prompt_file"
  return $rc
}

codex_run() { # ENDPOINT MODEL EFFORT PROMPT_FILE DIR OUT_FILE  (executor / write mode)
  local _ep="$1" model="$2" eff="$3" pf="$4" dir="$5" of="$6"
  local prompt_file; prompt_file="$(mktemp)"
  { _codex_single_agent_guard executor; ens_digest_prompt "$pf"; } >"$prompt_file"
  local _e; [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  # --sandbox workspace-write: OS-enforced — the executor may edit files only within
  # the worktree (-C DIR). The freeform response + ===DIGEST=== trailer go to stdout
  # -> OUT; stderr inherits fd2 (model-cli's ERR) for auth/quota classification.
  (
    _codex_clear_parent_env
    ens_run_timeout 1200 -- codex exec \
      --ignore-user-config --sandbox workspace-write --ephemeral \
      -c "model_reasoning_effort=$eff" -m "$model" \
      -C "$dir" \
      - <"$prompt_file" >"$of"
  )
  local rc=$?
  rm -f "$prompt_file"
  [ "$_e" -eq 1 ] && set -e || true
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
