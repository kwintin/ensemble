# shellcheck shell=bash
# vibe transport adapter (Mistral — mistral-medium-3.5).
# Uses ens_text_cli_review; vibe requires the prompt inline in -p (ignores stdin).
# Effort level is IGNORED: thinking depth is set in the vibe model config.

[ -n "${_ENS_ADAPTER_COMMON:-}" ] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/adapter_common.sh"

vibe_review() { # ENDPOINT MODEL EFFORT PROMPT_FILE OUT_FILE
  local ep="$1" model="$2" eff="$3" pf="$4" of="$5"
  # eff deliberately unused; thinking level is controlled by vibe model config.
  # ens_text_cli_review handles the set +e / restore-e dance internally.
  VIBE_ACTIVE_MODEL="$model" ens_text_cli_review "$of" -- \
    vibe -p "$(ens_sentinel_prompt "$pf")" --max-turns 1 --trust --output text
}

vibe_health() { # -> ok | auth | missing
  command -v vibe >/dev/null 2>&1 || { echo missing; return 0; }
  local cfg="${ENS_VIBE_CONFIG:-$HOME/.vibe/config.toml}"
  [ -f "$cfg" ] || { echo auth; return 0; }
  # Check for at least one [[providers]] block with a non-empty api_key
  if python3 - "$cfg" <<'PY' 2>/dev/null; then
import sys, re, os
cfg_path = sys.argv[1]
cfg = open(cfg_path, encoding="utf-8", errors="replace").read()
# A [[providers]] block authenticates if it has an inline non-empty api_key, OR an
# api_key_env_var naming a var resolvable from the process env OR vibe's sibling
# ~/.vibe/.env file (where vibe actually stores the key). Block ends at the next
# table/array header (single [ or double [[). Accept single- or double-quotes.
envfile = {}
try:
    for ln in open(os.path.join(os.path.dirname(cfg_path), ".env"), encoding="utf-8", errors="replace"):
        ln = ln.strip()
        if ln and not ln.startswith("#") and "=" in ln:
            k, v = ln.split("=", 1)
            envfile[k.strip()] = v.strip().strip('"').strip("'")
except Exception:
    pass
def resolved(var):
    return (os.environ.get(var, "").strip() or envfile.get(var, "").strip())
in_provider = False
for line in cfg.splitlines():
    stripped = line.strip()
    if stripped == "[[providers]]":
        in_provider = True
        continue
    if stripped.startswith("["):       # any other header ends the block
        in_provider = False
        continue
    if in_provider:
        m = re.match(r'''^api_key\s*=\s*['"]([^'"]*)['"]''', stripped)
        if m and m.group(1).strip():
            sys.exit(0)  # inline non-empty api_key
        m = re.match(r'''^api_key_env_var\s*=\s*['"]([^'"]+)['"]''', stripped)
        if m and resolved(m.group(1)):
            sys.exit(0)  # key supplied via process env or ~/.vibe/.env
sys.exit(1)
PY
    echo ok
  else
    echo auth
  fi
}

vibe_list_models() { # -> model ids (alias values), one per line
  local cfg="${ENS_VIBE_CONFIG:-$HOME/.vibe/config.toml}"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" <<'PY' 2>/dev/null
import sys, re
cfg = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# Print each alias value from [[models]] blocks (single- or double-quoted). A
# block ends at the next table/array header (single [ or double [[).
in_model = False
for line in cfg.splitlines():
    stripped = line.strip()
    if stripped == "[[models]]":
        in_model = True
        continue
    if stripped.startswith("["):       # any other header ends the block
        in_model = False
        continue
    if in_model:
        m = re.match(r'''^alias\s*=\s*['"]([^'"]*)['"]''', stripped)
        if m and m.group(1):
            print(m.group(1))
PY
}
