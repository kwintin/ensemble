---
description: Multi-model consensus review of the current diff (or a given scope) — dispatch independent reviewers, synthesize, and drive the fix-and-re-review loop.
argument-hint: "[--council] [--reviewers a,b,c] [--keep-work] [scope: paths or a file]"
---

Run a multi-model consensus review. Scope/flags: $ARGUMENTS

Use the `multi-model-review` skill. Default scope = the current `git diff` (uncommitted + last commit) if none given. Dispatch via `"$CLAUDE_PLUGIN_ROOT/scripts/ens-review.sh"`, then synthesize the combined JSON and drive the fix-and-re-review loop to consensus. Report the reconciled findings and verdict.

If `--council` is passed, use the skill's **Council mode**: convene via `"$CLAUDE_PLUGIN_ROOT/scripts/ens-council.sh"` (de-biased two-round review) and synthesize as chairman, preserving dissent.

Caps: reviewer prose lands in `reviewers[].review`, capped at `ENSEMBLE_REVIEW_CAP` characters (default `20000`, `0` = uncapped). If a record has `review_truncated: true`, raise the cap or pass `--keep-work` to keep the run's work directory (path printed to stderr) and read the full text from `<endpoint>.out` before drawing conclusions.

Provenance: each dispatch logs `▶/◀ … cli=… model=… family=…`; silence with `ENSEMBLE_PROVENANCE=0`.
