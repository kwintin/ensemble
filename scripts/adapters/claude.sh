# shellcheck shell=bash
# Claude Code transport adapter. Requires lib/timeout.sh (ens_run_timeout) and
# lib/adapter_common.sh (ens_digest_prompt), both normally sourced by model-cli.
#
# The parent may itself be Claude Code with Ensemble loaded. Every child is put
# in Claude's native safe mode and has the parent/plugin environment removed so
# it cannot rediscover Ensemble and recursively dispatch another ensemble.

[ -n "${_ENS_ADAPTER_COMMON:-}" ] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/adapter_common.sh"

_claude_clear_parent_env() {
  # The child must not inherit a direct route back to the outer Ensemble host.
  # Keep HOME/auth intact so Claude can authenticate, while safe mode disables
  # normal plugin, skill, hook, MCP, and project-customization discovery.
  unset CLAUDECODE CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA \
    ENSEMBLE_PLUGIN_ROOT ENSEMBLE_DATA_DIR ENSEMBLE_ROSTER \
    PLUGIN_ROOT PLUGIN_DATA CODEX_HOME
}

_claude_effort() { # ENSEMBLE_EFFORT -> Claude effort
  case "$1" in
    minimal) echo low ;;
    low|medium|high|xhigh) echo "$1" ;;
    *) echo medium ;;
  esac
}

_claude_verdict_schema() { # -> inline JSON Schema accepted by --json-schema
  # Keep this shape identical to the normalized JSON review contract consumed
  # by lib/verdict.sh. Claude returns it inside the result envelope's
  # `structured_output` property.
  cat <<'JSON'
{"type":"object","additionalProperties":false,"required":["verdict","findings"],"properties":{"verdict":{"type":"string","enum":["APPROVED","CHANGES"]},"findings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["file","line","severity","issue"],"properties":{"file":{"type":"string"},"line":{"type":"integer"},"severity":{"type":"string"},"issue":{"type":"string"}}}}}}
JSON
}

_claude_review_prompt() { # PROMPT_FILE -> guarded review prompt
  local pf="$1"
  cat <<'HDR'
READ-ONLY REVIEW. Do not edit, create, or delete files. Do not apply fixes. Do not invoke Ensemble, Claude Code, subagents, or any other reviewers. Perform one independent review using only the read-only repository tools available to you.

Return APPROVED only when there are no issues worth fixing; otherwise return CHANGES and include concrete findings.

--- REVIEW REQUEST ---
HDR
  cat "$pf"
  cat <<'FTR'

--- END REVIEW REQUEST ---
FTR
}

_claude_executor_prompt() { # PROMPT_FILE -> guarded executor prompt
  local pf="$1"
  cat <<'HDR'
You are ONE independent executor inside an outer Ensemble run. Complete this delegated task yourself. Do not invoke Ensemble (including its skills, commands, or scripts), Claude Code, Codex, model CLIs, other agents, or subagents.

HDR
  ens_digest_prompt "$pf"
}

_claude_extract_structured() { # RAW_RESULT_JSON OUT_FILE
  local raw="$1" of="$2"
  # A successful `claude -p --output-format json --json-schema ...` response is
  # an envelope; model-cli expects only its structured verdict object. Treat a
  # malformed/missing object as empty output so model-cli maps it to exit 3.
  # Truncate first: callers that reuse OUT must never retain a stale verdict.
  : >"$of"
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        envelope = json.load(f)
    if not isinstance(envelope, dict):
        raise ValueError("result envelope is not an object")
    if envelope.get("type") != "result":
        raise ValueError("unexpected result type")
    if envelope.get("subtype") != "success" or envelope.get("is_error") is True:
        raise ValueError("Claude returned an error result")
    value = envelope.get("structured_output")
    valid = (
        isinstance(value, dict)
        and set(value) == {"verdict", "findings"}
        and value.get("verdict") in ("APPROVED", "CHANGES")
        and isinstance(value.get("findings"), list)
        and all(
            isinstance(item, dict)
            and set(item) == {"file", "line", "severity", "issue"}
            and isinstance(item.get("file"), str)
            and isinstance(item.get("line"), int)
            and not isinstance(item.get("line"), bool)
            and isinstance(item.get("severity"), str)
            and isinstance(item.get("issue"), str)
            for item in value.get("findings", [])
        )
    )
    if valid:
        with open(sys.argv[2], "w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False, separators=(",", ":"))
            f.write("\n")
except Exception:
    pass
' "$raw" "$of"
}

claude_review() { # ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE
  local _ep="$1" model="$2" eff="$3" pf="$4" of="$5"
  local prompt_file schema raw rc ceff _e
  prompt_file="$(mktemp)"
  _claude_review_prompt "$pf" >"$prompt_file"
  schema="$(_claude_verdict_schema)"
  ceff="$(_claude_effort "$eff")"
  raw="$(mktemp)"
  [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  (
    # CLAUDECODE normally prevents nesting Claude Code. Removing it permits the
    # intentional child; safe mode plus the stripped plugin pointers prevents
    # that child from loading Ensemble again. Verified against claude 2.1.241:
    # a child launched with exactly these flags reports no plugins, skills, MCP
    # servers, or slash commands loaded, so Ensemble is not reachable from it.
    _claude_clear_parent_env
    export CLAUDE_CODE_SAFE_MODE=1
    ens_run_timeout 600 -- claude -p \
      --safe-mode \
      --no-session-persistence \
      --permission-mode plan \
      --tools "Read,Glob,Grep" \
      --allowed-tools "Read,Glob,Grep" \
      --model "$model" \
      --effort "$ceff" \
      --output-format json \
      --json-schema "$schema" \
      <"$prompt_file" >"$raw"
  )
  rc=$?
  _claude_extract_structured "$raw" "$of"
  rm -f "$prompt_file" "$raw"
  [ "$_e" -eq 1 ] && set -e || true
  return "$rc"
}

claude_run() { # ENDPOINT MODEL EFFORT PROMPT_FILE DIR OUT_FILE (executor)
  local _ep="$1" model="$2" eff="$3" pf="$4" dir="$5" of="$6"
  local prompt_file ceff rc _e sandbox_settings
  prompt_file="$(mktemp)"
  _claude_executor_prompt "$pf" >"$prompt_file"
  ceff="$(_claude_effort "$eff")"
  sandbox_settings='{"sandbox":{"enabled":true,"failIfUnavailable":true,"autoAllowBashIfSandboxed":true,"excludedCommands":[],"allowUnsandboxedCommands":false}}'
  [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  (
    cd "$dir" || { echo "claude_run: cannot enter worktree '$dir'" >&2; exit 125; }
    _claude_clear_parent_env
    export CLAUDE_CODE_SAFE_MODE=1
    # The caller creates DIR as a disposable worktree. acceptEdits and the
    # explicit allowlist make the executor autonomous there; excluding Agent,
    # Skill, and MCP tools also prevents delegation back into another agent.
    ens_run_timeout 1200 -- claude -p \
      --safe-mode \
      --no-session-persistence \
      --permission-mode acceptEdits \
      --settings "$sandbox_settings" \
      --tools "Read,Glob,Grep,Edit,Write,Bash" \
      --allowed-tools "Read,Glob,Grep,Edit,Write,Bash" \
      --model "$model" \
      --effort "$ceff" \
      --output-format text \
      <"$prompt_file" >"$of"
  )
  rc=$?
  rm -f "$prompt_file"
  [ "$_e" -eq 1 ] && set -e || true
  return "$rc"
}

claude_health() { # -> ok | auth | missing
  command -v claude >/dev/null 2>&1 || { echo missing; return 0; }
  local out rc result _e
  [[ $- == *e* ]] && _e=1 || _e=0
  set +e
  out="$(
    _claude_clear_parent_env
    ens_run_timeout 20 -- claude auth status --json 2>/dev/null
  )"
  rc=$?
  [ "$_e" -eq 1 ] && set -e || true
  [ "$rc" -eq 0 ] || { echo auth; return 0; }
  result="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
    print("ok" if isinstance(value, dict) and value.get("loggedIn") is True else "auth")
except Exception:
    print("auth")
' 2>/dev/null)"
  echo "${result:-auth}"
}

claude_list_models() { # -> stable Claude aliases, one per line
  command -v claude >/dev/null 2>&1 || return 0
  # Claude Code has no machine-readable model-list command. These aliases are
  # deliberately preferred over dated IDs so setup remains valid across model
  # rollovers handled by the installed Claude CLI.
  printf '%s\n' haiku sonnet opus
}
