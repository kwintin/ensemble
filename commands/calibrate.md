---
description: Ground each model's strengths in measurement — run a category-tagged fixture corpus through every enabled reviewer's real review path, score per-category hit-rate, and propose a roster strengths rewrite for your confirmation.
argument-hint: "[--endpoint <id>] [--category <cat>]"
---

Run ensemble calibration. $ARGUMENTS

Use the `ensemble-calibrate` skill. List the corpus and the enabled reviewers via `"$CLAUDE_PLUGIN_ROOT/scripts/ens-calibrate.sh" list` and `ens_reviewers`, **show the cost (endpoints × fixtures = N real review runs) and confirm before spending tokens**, then `ens-calibrate.sh run` (honoring any `--endpoint`/`--category` the user gave). If `run` exits 4 (nothing measured) report the skips and stop. Otherwise `ens-calibrate.sh propose` → show the old→new strengths diff (framed honestly: measured on N local fixtures; priors, not guarantees), **confirm**, then `ens-calibrate.sh apply`. Never spend tokens or write the roster without an explicit confirm.

Provenance: each dispatch logs `▶/◀ … cli=… model=… family=…`; silence with `ENSEMBLE_PROVENANCE=0`.
