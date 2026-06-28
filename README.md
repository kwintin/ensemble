<div align="center">

<img src="docs/assets/hero.png" alt="Ensemble — a conductor figure in orange directing four jewel-toned model-figures reaching toward a shared point of light" width="820">

# Ensemble

### Many models. One conductor.

A Claude Code plugin that turns a roster of independent AI model CLIs into an
**ensemble** — dispatched in parallel for consensus review, or routed by strength
for delegated work. Claude always conducts: it owns requirements, judgement,
synthesis, and verification.

</div>

---

> **Status:** early — design spec approved, implementation phasing underway.
> See [`docs/specs/`](docs/specs/) for the full design.

## What it does

Two engines over one hardened core:

- **Review** — send a diff, spec, plan, or doc to several independent models
  (each reached through its own CLI) for parallel, read-only review, then run a
  bounded fix-and-re-review loop to consensus. An opt-in **council mode** adds
  anonymized peer review with Claude as chairman for high-stakes changes.
- **Delegate** — route a well-scoped unit of work to the strength-matched model,
  run it in an isolated git worktree, and verify against a contract in a clean
  state before merging.
- **Calibrate** — ground each model's routing `strengths` in measurement: run a
  category-tagged fixture corpus through every enabled reviewer's real review path,
  score per-category hit-rate, and propose a roster rewrite (scored `category:score`
  tags, *measured on your fixtures*) for your confirmation. A prior you can stand
  behind, not a leaderboard.

The unit of selection is a **model endpoint** — *this model, reached via this
transport CLI* — so reviewer independence and strength routing track the model
family, not the CLI.

## Why a conductor and an ensemble

The other models are inputs: independent reviewers or strength-matched
executors, kept anonymous and equal. Claude reconciles their voices and owns
correctness — the standing figure to their reaching hands.

## Status & roadmap

| Phase | Scope |
|------|-------|
| 0 | Shared core — unified dispatcher, per-CLI adapters, roster, doctor, job registry, hermetic test harness |
| 1 | Review engine — hardened consensus loop + council mode, setup wizard, gating |
| 2 | Delegate engine — strength routing, worktree isolation, clean-state verification |
| 3 | Polish — docs, marketplace manifest, cross-platform notes |

Configuration is roster-driven, so the plugin adapts to whatever CLIs you have
installed rather than hardcoding a fixed set.
