# Changelog

Notable changes to Ensemble, newest first.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [semantic versioning](https://semver.org/spec/v2.0.0.html). Releases are
tagged `ensemble--v<version>`, the tag name `claude plugin tag` creates and validates.

Entries for 0.2.0 and earlier were reconstructed from git history after the fact, so
they summarise each release rather than enumerate it.

## [0.2.1] — 2026-08-24

Review prose was being destroyed in transit. This release stops that, and makes every
remaining cap visible.

### Fixed

- **Reviewer prose is no longer truncated at 4000 characters.** `reviewers[].review` was
  sliced at a hardcoded 4000 with no flag or env var to change it. For a `sentinel`
  reviewer the prose *is* the review — its `findings[]` is empty by construction — so the
  cap was silently deleting real findings. Observed live: six sentinel reviewers over a
  ~600-line file all came back at exactly 4000 chars, three cut mid-enumeration.
- **Council mode was de-biasing on mutilated input.** `ens-council.sh` builds its
  anonymized peer block from round 1's `review` field, so every peer round critiqued
  reviews with the tails already removed and was asked "what did the others miss" about
  text it was never shown. A correctness bug in the de-biasing mechanism, not a cosmetic
  one. The peer block now also marks any review a cap did trim.
- **Sentinel reviewers no longer report `(0 findings)`.** The progress line and merged
  outcome were built from `len(findings)` for every reviewer, a count that is
  structurally always zero in sentinel mode. In one six-reviewer run all six reported
  `0 findings` while collectively raising ~20 issues, four of them genuine bugs. The
  outcome is now derived from the endpoint's `structured_output` mode: `json` keeps
  `(N findings)`, `sentinel` reports `(N chars prose)`. No count is fabricated by parsing
  the prose.
- **Delegate stderr truncation is no longer silent** — the same hardcoded-slice shape,
  now capped explicitly and reported.

### Added

- **`--keep-work`** on `review` and `council`. Skips the work-dir teardown and prints the
  retained path to stderr, so the untruncated reviewer text in `<endpoint>.out` stays
  recoverable. Council propagates it to both rounds. Honoured on every exit path,
  including `INT`/`TERM`. The disposable review worktree is still removed either way — it
  is registered with your repo, and keeping it would dirty real state.
- **`ENSEMBLE_REVIEW_CAP`** (default `20000`, `0` = uncapped) and **`ENSEMBLE_STDERR_CAP`**
  (default `2000`, `0` = uncapped). A malformed value falls back to the default with a
  warning rather than producing a nonsense slice. Shared validation lives in
  `scripts/lib/cap.sh`.
- Additive JSON fields: `reviewers[].output_mode`, `review_truncated`, `review_chars`, a
  top-level `review_cap`, and `stderr_truncated` / `stderr_chars` on a delegate result.
- Regression coverage: a `long` grok stub emitting ~10.6k chars of prose, a sentinel
  roster fixture, and tests for default/configured/uncapped/malformed caps, both
  truncation signals, `--keep-work` retention vs. default teardown, and council
  peer-prompt fidelity. Suite: 405 → 458 checks, green.

### Compatibility

Additive and backward compatible: no key renamed or removed, and exit-code semantics are
unchanged (`0` quorum met, `4` below quorum / could not convene, `5` read-only violation).
Two visible behaviour changes: reviews come back longer, and sentinel `◀` lines read
`CHANGES (8213 chars prose)` instead of `CHANGES (0 findings)`.

## [0.2.0] — 2026-08-24

### Added

- **Codex host support** — `.codex-plugin/plugin.json`, the host-neutral
  `scripts/ensemble` launcher, and an `ensemble-doctor` skill, so the same engines run
  under Codex or Claude Code.
- **Claude transport** — a `sonnet@claude` endpoint and `scripts/adapters/claude.sh`,
  reviewer and executor capable.

### Fixed

- **The wall-clock guard now verifies its backend before trusting it.** `timeout(1)` and
  the perl path are both driven by `alarm(2)`; on a host whose timers do not fire they
  run the child to completion and return *its* exit status — a guard that silently does
  nothing, which is worse than no guard, since every caller believes it is protected. A
  backend that fails to interrupt a live child is now skipped in favour of the timerless
  python3 path, and `doctor` reports which one is in use.

## [0.1.1] — 2026-06-29

### Fixed

- `doctor` retries flapping health probes, instead of reporting a false `auth` failure on
  a live endpoint.
- `delegate merge` never commits ephemeral artifacts (bytecode, caches) an executor
  produced by running the code — including artifacts the executor staged itself.
- The review read-only guard ignores those same ephemeral artifacts, so a reviewer that
  runs the code no longer false-positives to exit `5`.
- Calibration fixtures tightened: bug-revealing comments stripped, loose `must_match`
  patterns sharpened, and 12 harder discriminating fixtures added.

### Note

The provenance work — the `▶`/`◀` dispatch lines, `ens_endpoint_fields`, `cli`/`model`/
`family` in the emitted JSON, and the `ENSEMBLE_PROVENANCE` toggle — landed *after* the
0.1.1 bump and shipped under that version number until 0.2.0.

## [0.1.0] — 2026-06-28

Initial release: the review engine with worktree-isolated read-only reviewers, quorum by
model family, council mode, the delegate engine, calibrate, setup, and doctor, across the
codex/agy/grok/opencode/kilo/vibe transports.
