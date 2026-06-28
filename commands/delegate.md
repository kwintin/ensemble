---
description: Delegate one well-scoped implementation unit to a strength-matched executor model in an isolated git worktree, then verify it in a clean state and merge.
argument-hint: "[--endpoint id] [--strength tag] <task>"
---

Delegate an implementation unit. Args/flags: $ARGUMENTS

Use the `delegate-implementation` skill. First define the acceptance gate (the tests/checks that mean done). Route to the best-fit executor by its `strengths` (override with `--endpoint id` or `--strength tag`) and state why. Run the unit via `"$CLAUDE_PLUGIN_ROOT/scripts/ens-delegate.sh" run --endpoint <id> --prompt-file <task>` (isolated worktree). Then VERIFY the worktree yourself in a clean state — never trust the executor's self-reported success — and either `ens-delegate.sh merge` it or `ens-delegate.sh discard` and reroute/retry. Optionally pipe the worktree diff through `/ensemble:review` before merge.
