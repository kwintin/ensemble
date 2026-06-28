# shellcheck shell=bash
# Resolve the active roster. Precedence:
#   1. ENSEMBLE_ROSTER (explicit override — tests, scripted use)
#   2. $CLAUDE_PLUGIN_DATA/roster.json (personalized copy written by /ensemble:setup;
#      survives plugin updates)
#   3. $ROOT/roster.json (the shipped default, so the plugin works before setup)
# Requires ROOT to be set by the caller. Sets ROSTER.
if [ -n "${ENSEMBLE_ROSTER:-}" ]; then
  ROSTER="$ENSEMBLE_ROSTER"
elif [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -f "$CLAUDE_PLUGIN_DATA/roster.json" ]; then
  ROSTER="$CLAUDE_PLUGIN_DATA/roster.json"
else
  ROSTER="$ROOT/roster.json"
fi
