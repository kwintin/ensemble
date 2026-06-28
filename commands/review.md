---
description: Multi-model consensus review of the current diff (or a given scope) — dispatch independent reviewers, synthesize, and drive the fix-and-re-review loop.
argument-hint: "[--council] [--reviewers a,b,c] [scope: paths or a file]"
---

Run a multi-model consensus review. Scope/flags: $ARGUMENTS

Use the `multi-model-review` skill. Default scope = the current `git diff` (uncommitted + last commit) if none given. Dispatch via `"$CLAUDE_PLUGIN_ROOT/scripts/ens-review.sh"`, then synthesize the combined JSON and drive the fix-and-re-review loop to consensus. Report the reconciled findings and verdict.

If `--council` is passed, use the skill's **Council mode**: convene via `"$CLAUDE_PLUGIN_ROOT/scripts/ens-council.sh"` (de-biased two-round review) and synthesize as chairman, preserving dissent.
