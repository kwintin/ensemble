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
3. **Synthesize (your judgement).** Read the combined JSON. Build a consensus table (endpoint · verdict · key findings). A finding flagged by 2+ distinct families is high-confidence; a lone finding is assessed against the real code before acting; `family_collisions` are the same model — count them once. Resolve disagreement with evidence from the code, not a vote.
4. **Fix → re-review.** If issues: fix them, commit, then re-run the engine with `--reviewers` (a comma-separated list of endpoint ids) limited to the endpoints from the families that flagged issues. Stop when every OK family verdict is APPROVED, or after `max_rounds` (default 3).
5. **Report.** Reconciled findings (most severe first) + the verdict.

## Rules
- Independence is by model **family**, never transport count.
- Never re-review without fixing first. Commit between rounds so reviewers see current state.
- A reviewer that degraded (auth/quota/timeout) is skipped while quorum holds — do not block on it.
