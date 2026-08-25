---
description: Interactive setup wizard — detect installed/authenticated model CLIs, pick which models to enable per transport, and write a personalized ensemble roster.
argument-hint: ""
---

Run the ensemble setup wizard. $ARGUMENTS

Use the `ensemble-setup` skill. Detect transports via `"$CLAUDE_PLUGIN_ROOT/scripts/ens-setup.sh" detect`, ask the user which models to enable per transport (multi-select), tag each with an engine-safe id + family/role/strengths (using `ens-setup.sh idfor|family|defaults`), run the diversity check, then write + validate the roster at the single target path the skill computes (`$TARGET`: the host's writable plugin data dir, which survives plugin updates). Finish by suggesting `/ensemble:doctor`.
