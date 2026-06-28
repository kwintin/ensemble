# Calibration fixture corpus

`/ensemble:calibrate` runs this corpus through each enabled endpoint's real review
path and measures per-category hit-rate, then proposes a roster `strengths` rewrite
(scored `category:score` tags) for your confirmation. See
`docs/specs/2026-06-28-ensemble-calibrate-design.md`.

These are **starter** fixtures — coarse and few. Extend them with your own (more
fixtures per category = a more trustworthy `N`). The honesty framing holds: a score is
*measured on your fixtures, through your CLI harness* — a prior, not a guarantee.

## Layout

```
fixtures/
  <category>/
    <fixture-name>/
      input.<ext>      # ONE small code sample with one planted defect
      expect.json      # the grading contract
```

- **The category vocabulary is the set of immediate subdirectory names here** — the
  single source of truth that both the seeded defaults (`data/model-defaults.json`) and
  calibrated scores align to. This README is *derivative* documentation of those names.
- A category name must be a **slug**: `^[a-z0-9][a-z0-9-]*$` (lowercase, digits,
  hyphens) so it is safe as a directory name and as a literal in the strengths predicate.
- Keep `input.*` **small** (target < ~4 KB): the file's *content* is embedded into the
  review prompt (the CLIs read prompt text, not the workspace), so a huge file risks the
  OS `ARG_MAX` limit.

## Canonical categories (v1)

| category | defect class to plant |
|---|---|
| `bugs` | correctness (off-by-one, empty-collection, mutable default, wrong operator) |
| `injection` | SQL / shell / path injection via unsanitized input |
| `payment-logic` | money math / rounding / currency / fractional-cents |
| `perf` | accidentally-quadratic, N+1, unbounded growth |
| `type-drift` | signature/return-type mismatch across call sites |
| `concurrency` | race / unguarded shared state / serialized awaits |

To add a category, create a new `fixtures/<slug>/` directory with fixtures — calibrate
picks it up automatically (and a matching `<slug>:<score>` strengths tag becomes
available). Categories `bugs`, `perf`, `concurrency` have no seeded synonym; they start
unscored and calibration fills them.

## `expect.json` grading contract

```json
{
  "category": "injection",
  "verdict": "CHANGES",
  "must_match": ["sql injection|injection", "parameteriz|prepared|placeholder|bind|\\?|%s"],
  "must_match_mode": "all",
  "note": "raw SQL built from user input; expect param-binding advice"
}
```

- `category` (required) — **must equal the parent directory name**.
- `verdict` (required) — `CHANGES` for a planted bug (the common case), or `APPROVED`
  for a clean *control* fixture.
- `must_match` (required, non-empty for `CHANGES`; may be `[]` for `APPROVED` controls) —
  Python `re` patterns (`re.search`, case-insensitive) applied to the model's review
  prose. Author them to key on the **defect concept**, not one exact phrasing, so a model
  that finds the bug in its own words still scores a hit (e.g. SQL injection matched by
  `parameteriz|prepared|bind`, not the literal string "SQL injection").
- `must_match_mode` (`"all"` | `"any"`, default `"all"`).
- `note` (optional) — human description; ignored by scoring.

## How a fixture is graded (summary)

A fixture is **graded** when the endpoint returns a usable review (parseable envelope
with non-empty prose); an outage / auth / quota / timeout / crash is a **skip** (excluded
from the score, never a fabricated `0.0`). For a `CHANGES` fixture, a **hit** =
`must_match` is satisfied over the review prose and the verdict is not `APPROVED`. A
small `N` (e.g. 2 fixtures) yields a coarse score (`{0, 0.5, 1.0}`) — add fixtures for a
finer measure.
