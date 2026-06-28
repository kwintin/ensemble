---
description: Interactive setup wizard — detect installed/authenticated model CLIs, pick which models to enable per transport, and write a personalized ensemble roster.
argument-hint: ""
---

Run the ensemble setup wizard. $ARGUMENTS

Use the `ensemble-setup` skill. Detect transports via `"$CLAUDE_PLUGIN_ROOT/scripts/ens-setup.sh" detect`, ask the user which models to enable per transport (multi-select), tag each with family/role/strengths (using `ens-setup.sh family|defaults`), run the diversity check, then write + validate `$CLAUDE_PLUGIN_DATA/roster.json`. Finish by suggesting `/ensemble:doctor`.
