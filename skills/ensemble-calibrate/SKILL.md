---
name: ensemble-calibrate
description: Ground a model endpoint's `strengths` in measurement for Ensemble — run a category-tagged fixture corpus through each enabled reviewer's real review path, measure per-category hit-rate, and propose a roster strengths rewrite for the user to confirm. Use for Ensemble calibration or when the user wants to ground or refresh routing strengths from real runs.
---

# Ensemble Calibrate

Drive a four-step flow. The engine measures and mutates. **Token spend happens only in
`run`, and the roster is only changed by `apply` — require explicit user confirmation
before either command.**

## Launcher

Prefer the plugin root the host exports, and fall back to this skill's own location.
Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md`, then set:

```bash
ENSEMBLE_ROOT="${ENSEMBLE_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$SKILL_DIR/../.." && pwd)}}}"
ENSEMBLE="$ENSEMBLE_ROOT/scripts/ensemble"
```

Never resolve the launcher from the current working directory. Run calibration as `"$ENSEMBLE" calibrate <verb>`.

Honesty framing (state it to the user): *Ensemble does not claim to know each model's
strengths. A calibrated score is measured on your local fixtures, through your CLI
harness — a routing prior, not a guarantee. Delegate work is verified against your tests
and review relies on family diversity, so an inaccurate prior degrades gracefully.*

## The flow

1. **List + preview cost.**
   ```bash
   "$ENSEMBLE" calibrate list           # {categories,total,fixtures}
   ```
   Enabled reviewers come from the roster (`ens_reviewers`, via `scripts/lib/roster.sh`
   + `roster-path.sh`). Compute `runs = endpoints × fixtures` (respecting any
   `--endpoint`/`--category` the user asked for). State it plainly: "this runs N real
   reviews across M models — minutes and tokens." Offer the cheaper scoped forms
   (`--endpoint <id>` for one model, `--category <cat>` for one category).
   **Ask the user to confirm before spending and wait for the answer.** If the corpus is empty
   (`list` exits 3), tell them and stop.

2. **Run.**
   ```bash
   "$ENSEMBLE" calibrate run [--endpoint ID] [--category CAT] > result.json
   ```
   Each fixture is reviewed in an isolated temp git repo (the user's tree is never
   touched). Progress goes to stderr; the result JSON to stdout — capture it.
   - **Exit 4 = nothing measured** (every fixture skipped — outage/auth/quota). Report the
     skip reasons from `result.ran[].fixtures[].reason` and **stop** — do not propose.
   - Otherwise continue. Surface per-category scores and any skips (e.g. "injection 0.88
     (n=8); perf skipped 2 — codex quota").

3. **Propose.**
   ```bash
   "$ENSEMBLE" calibrate propose --result result.json
   ```
   Emits a proposed roster (temp path) + an old→new strengths diff on stderr. Show the
   diff. Each measured category becomes a `category:score` tag (sorted, scored first);
   un-tested priors are preserved as bare tags; a fully-skipped endpoint is left
   untouched. Note small-`N` scores are coarse (e.g. n=2 → {0, 0.5, 1.0}) and that bare
   tags are uncalibrated priors. **Ask the user to confirm applying.**

4. **Apply** (only on confirm).
   ```bash
   "$ENSEMBLE" calibrate apply --proposed <proposed-path>
   ```
   Validates the proposal, backs up the live roster to `<roster>.bak`, and atomically
   writes the active roster (`$ENSEMBLE_ROSTER` when explicitly set, otherwise
   `$ENSEMBLE_DATA_DIR/roster.json` — the same path `ensemble setup` writes). **Warn before re-applying** (a
   second apply overwrites the `.bak`). Report the written path and backup. On "no",
   discard the proposed temp file and change nothing.

## Notes
- `--endpoint`/`--category` bound the cost; a full run is `endpoints × fixtures`.
- Re-run anytime to refresh; calibrated tags override seeded defaults in place.
- The corpus lives in `fixtures/` (see `fixtures/README.md`); users can extend it — more
  fixtures per category give a more trustworthy `N`.
- If `apply` exits 5 it refused (invalid or degraded proposal); the live roster is
  untouched — report and stop.

**Surface provenance.** The engine prints a `▶`/`◀` line per dispatch (cli/model/family); when you report results, name the cli/model/family that produced each verdict/output (and, for delegate, the routing reason) so the user always knows which model did what. Set `ENSEMBLE_PROVENANCE=0` to silence the lines.
