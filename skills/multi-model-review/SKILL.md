---
name: multi-model-review
description: Dispatch a diff, spec, plan, or document to multiple independent model reviewers (via ens-review.sh) for parallel read-only review, then synthesize findings and drive a fix-and-re-review loop to consensus. Use for code/spec/plan review, multi-model sign-off, or when the user asks for consensus/cross-model review.
---

# Multi-Model Review

Drive an independent multi-reviewer consensus loop over the ensemble core.

## The loop
1. **Scope.** Build ONE self-contained review prompt from the artifact (a `git diff`, a spec/plan file, or text). Reviewers have no conversation context — inline what they need.
2. **Dispatch.** Run the engine (it fans out enabled reviewers in parallel, enforces quorum + family-independence + read-only, and returns one combined JSON):
   ```bash
   git diff | "$CLAUDE_PLUGIN_ROOT/scripts/ens-review.sh" -            # review the diff
   "$CLAUDE_PLUGIN_ROOT/scripts/ens-review.sh" --prompt-file SPEC.md   # review a file
   ```
   Exit `0` = quorum met; `4` = below quorum (tell the user which reviewers are unavailable, suggest `/ensemble:doctor`); `5` = a reviewer tried to write files (reviewers run in a disposable worktree copy, so your real tree is never touched — treat that reviewer's findings as untrusted and see `mutated_files`).
3. **Synthesize (your judgement).** Read the combined JSON. Build a consensus table (endpoint · verdict · key findings). Structured reviewers (codex) carry detail in `findings[]`; sentinel reviewers (agy/grok/vibe/opencode/kilo) carry it as prose in the `review` field — read both. A finding flagged by 2+ distinct families is high-confidence; a lone finding is assessed against the real code before acting; `family_collisions` are the same model — count them once. Resolve disagreement with evidence from the code, not a vote.
4. **Fix → re-review.** If issues: fix them, commit, then re-run the engine with `--reviewers` (a comma-separated list of endpoint ids) limited to the endpoints from the families that flagged issues. Stop when every OK family verdict is APPROVED, or after `max_rounds` (default 3).
5. **Report.** Reconciled findings (most severe first) + the verdict.

## Rules
- Independence is by model **family**, never transport count.
- Never re-review without fixing first. Commit between rounds so reviewers see current state.
- A reviewer that degraded (auth/quota/timeout) is skipped while quorum holds — do not block on it.

## Council mode (`--council`)
For high-stakes review (spec sign-off, auth/billing/crypto), run a **de-biased two-round** review instead of the single pass. ~2× the calls.

1. **Convene.** Run the council engine (it does round-1, anonymizes the reviews, runs a peer round, and returns both rounds + a de-anonymization map):
   ```bash
   git diff | "$CLAUDE_PLUGIN_ROOT/scripts/ens-council.sh" -
   ```
   It emits `{mode, anon_labels, round1, round2}`. Exit `4` = couldn't convene (fewer than 2 OK reviewers); `5` = a reviewer wrote files (untrusted). In the peer round each reviewer saw the anonymized set (labelled A.., identity stripped — including its own) and was asked what the others *missed* or got *wrong*.
2. **Chair (your judgment).** Read both rounds. Synthesize as the chairman — do **not** just take the majority: weigh how each reviewer's position **moved** between round-1 and the peer round, and side with a strong minority when the artifact supports it. Report with explicit dissent — for each material finding: **Agrees** (who/why), **Clashes** (who/why), **What-You-Lose** (the cost of the call you make). Then the verdict.
3. **Fix → re-review** as in the normal loop (re-run `--council` only if the change is itself high-stakes; otherwise a plain re-review suffices).

## Read-only safety
- Reviewers run cd'd into a disposable `git worktree` copy at HEAD (your uncommitted tracked changes replayed in), so the engine never writes to your real working tree. `wip_replayed` reports whether that replay succeeded.
- This isolates working-tree **files**. It does not sandbox a reviewer that deliberately runs git/shell commands against shared refs/stash/config or writes to absolute paths — the codex reviewer runs under `--sandbox read-only`; the others run in plan/read-only mode and are trusted not to.
- `read_only_guarded: true` means isolation was in force. If `false` (you are not inside a git repo), reviewers ran in the current directory unguarded — the engine warns on stderr; treat a `false` run as best-effort. Inside a git repo, if isolation can't be created the engine fails closed (non-zero) rather than run unguarded.
