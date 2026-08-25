# shellcheck shell=bash
# Resolve the active roster. Precedence:
#   1. ENSEMBLE_ROSTER (explicit override — tests, scripted use)
#   2. $ENSEMBLE_DATA_DIR/roster.json (host-neutral explicit data directory)
#   3. $PLUGIN_DATA/roster.json (Codex plugin writable data directory)
#   4. $CLAUDE_PLUGIN_DATA/roster.json (Claude plugin writable data directory)
#   5. ${CODEX_HOME:-$HOME/.codex}/plugins/data/ensemble/roster.json (the launcher's
#      last-resort data dir — kept here so a script sourced WITHOUT the launcher
#      resolves the same roster the launcher would have exported)
#   6. $ROOT/roster.json (the shipped default, so the plugin works before setup)
# Data-directory candidates are selected only when their roster already exists;
# setup/calibration use the same order without that requirement for copy-on-write.
# Callers set ROOT; if they didn't, derive it from this file's location so the
# shipped fallback never resolves to a bare "/roster.json".
: "${ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if [ -n "${ENSEMBLE_ROSTER:-}" ]; then
  ROSTER="$ENSEMBLE_ROSTER"
elif [ -n "${ENSEMBLE_DATA_DIR:-}" ] && [ -f "$ENSEMBLE_DATA_DIR/roster.json" ]; then
  ROSTER="$ENSEMBLE_DATA_DIR/roster.json"
elif [ -n "${PLUGIN_DATA:-}" ] && [ -f "$PLUGIN_DATA/roster.json" ]; then
  ROSTER="$PLUGIN_DATA/roster.json"
elif [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -f "$CLAUDE_PLUGIN_DATA/roster.json" ]; then
  ROSTER="$CLAUDE_PLUGIN_DATA/roster.json"
elif [ -n "${CODEX_HOME:-}" ] && [ -f "$CODEX_HOME/plugins/data/ensemble/roster.json" ]; then
  ROSTER="$CODEX_HOME/plugins/data/ensemble/roster.json"
elif [ -n "${HOME:-}" ] && [ -f "$HOME/.codex/plugins/data/ensemble/roster.json" ]; then
  ROSTER="$HOME/.codex/plugins/data/ensemble/roster.json"
else
  ROSTER="$ROOT/roster.json"
fi
