---
name: delegate-implementation
description: Route one well-scoped implementation unit to the strength-matched executor model, run it write-enabled in an isolated git worktree, verify it yourself in a clean state, then merge or reroute. Use for /ensemble:delegate or when offloading a self-contained coding unit to another model.
---

# Delegate Implementation (strength-routed)

Offload ONE well-scoped unit to the best-fit executor model, **verify it yourself**, then merge. You stay the architect and the verification oracle; the executor is a hired hand working in a sandboxed copy.

## The loop
1. **Contract first — you own it.** Before delegating, write/define the acceptance gate (the tests or checks that mean *done*). This is both the executor's target and YOUR verification oracle. Put shared rules in a repo-root `AGENTS.md` so the executor follows what you follow.
2. **Route by strength.** Pick the executor endpoint whose `strengths` (a model property) best fit the unit; honor `role: executor|both` and the latency tier. Consult the roster:
   ```bash
   bash -c 'source "$CLAUDE_PLUGIN_ROOT/scripts/lib/roster.sh"; ens_executors "${ENSEMBLE_ROSTER:-$CLAUDE_PLUGIN_ROOT/roster.json}"'  # id <tab> strengths <tab> latency
   ```
   **State why** you routed where you did. `--endpoint id` / `--strength tag` override your judgment.
3. **Delegate one unit.** Run the engine — it creates an isolated worktree, runs the executor write-enabled in it, and returns a JSON result; the worktree is LEFT in place:
   ```bash
   "$CLAUDE_PLUGIN_ROOT/scripts/ens-delegate.sh" run --endpoint <id> --prompt-file <TASK>
   ```
   Result: `{endpoint, status, signal, worktree, branch, files_changed, diff_stat, digest}`. The executor's writes are isolated to `worktree`; read the `digest` (===DIGEST=== trailer: files / decisions / context) and `diff_stat`, not raw output.
4. **Verify in a clean state — the trust boundary.** Re-run the acceptance gate **inside the worktree** from a pristine checkout/deps. Executors have been measured patching their own environment to fake a pass — **never trust the executor's self-reported success.** Inspect the diff for scope creep (the worktree contains the *expected* writes; codex is OS-sandboxed to it, the others rely on cwd — confirm the change is on-task).
5. **Merge or reroute.**
   - pass → `"$CLAUDE_PLUGIN_ROOT/scripts/ens-delegate.sh" merge --worktree <worktree> [--message "..."]` (commits + merges the unit, removes the worktree).
   - fail → `"$CLAUDE_PLUGIN_ROOT/scripts/ens-delegate.sh" discard --worktree <worktree>` then: retry with more context, reroute to another executor, or implement it yourself.
6. **Optional sign-off.** Before merging a risky unit, pipe the worktree diff through `/ensemble:review` (strength-routed implementation → multi-model review).

## Rules
- **One isolated unit per delegation.** Decompose larger work and delegate units independently (parallel-safe — each gets its own worktree).
- **You verify, always.** Step 4 is non-negotiable; a digest saying "tests pass" is a claim, not evidence.
- **Structured failures, not prose.** `signal` is `quota|auth|timeout|missing|failed|empty` (exit 10/11/12/13/2/3) — reroute/retry on it instead of scraping output.
- **Headless caveat.** Under `claude -p` there is no later turn to collect — verify + merge/discard synchronously in the same run.
- **Containment.** The worktree is the boundary for *expected* writes. Only codex (`--sandbox workspace-write`) is OS-contained; agy/grok/opencode/kilo rely on cwd + auto-approve and could in principle write elsewhere — the clean-state verify + diff inspection is your backstop.
