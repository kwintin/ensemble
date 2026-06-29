# Ensemble

### Many models. One conductor.

A Claude Code plugin that turns a roster of independent AI model CLIs into an
**ensemble** — dispatched in parallel for consensus review, or routed by strength
for delegated work. Claude always conducts: it owns requirements, judgement,
synthesis, and verification.

<img src="docs/assets/hero.jpg" alt="Ensemble — a conductor figure in orange directing four jewel-toned model-figures reaching toward a shared point of light" width="820">

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

## Requirements

- **Claude Code** (the host).
- **bash**, **python3** (3.8+), and **git** on `PATH` — the engines are bash + small
  embedded Python; isolation uses `git worktree`.
- **At least one** of the six supported model CLIs, installed and authenticated. The
  roster adapts to whatever you have — you do not need all six:

  | CLI | Transport / model | Roles |
  |-----|-------------------|-------|
  | `codex` | OpenAI Codex | reviewer + executor (OS-sandboxed read-only / workspace-write) |
  | `agy` | Antigravity (Gemini) | reviewer + executor |
  | `grok` | xAI Grok | reviewer + executor |
  | `opencode` | OpenCode (DeepSeek, …) | reviewer + executor |
  | `kilo` | Kilo (GLM, …) | reviewer + executor |
  | `vibe` | Mistral | reviewer only |

- **Optional:** GNU coreutils `timeout`/`gtimeout` for the robust wall-clock guard;
  without it the engines fall back to a portable perl/python guard (macOS:
  `brew install coreutils`).

Configuration is roster-driven, so the plugin adapts to whatever CLIs you have
installed rather than hardcoding a fixed set.

## Install

```bash
# add this repo as a plugin marketplace, then install the plugin
/plugin marketplace add kwintin/ensemble      # or a local path to this checkout
/plugin install ensemble@ensemble-for-claude-code
```

Then configure your roster from the CLIs you actually have:

```
/ensemble:setup      # detect installed + authenticated CLIs, pick models, write the roster
/ensemble:doctor     # verify endpoints are healthy (quorum is by model family)
```

The roster persists to `$CLAUDE_PLUGIN_DATA/roster.json` (survives plugin updates); a
shipped default lets the plugin work before setup.

## Commands

| Command | What it does |
|---------|--------------|
| `/ensemble:review [--council] [--reviewers a,b,c] [scope]` | Multi-model consensus review of a diff/spec/plan/doc; `--council` runs a de-biased two-round anonymized review with Claude as chairman. |
| `/ensemble:delegate` | Route a well-scoped unit to the strength-matched executor; run it write-enabled in an isolated worktree; verify against a contract before merging. |
| `/ensemble:calibrate [--endpoint id] [--category cat]` | Measure each reviewer's per-category hit-rate on a fixture corpus and propose grounded `category:score` strengths. |
| `/ensemble:setup` | Detect installed/authenticated CLIs and write a personalized roster. |
| `/ensemble:doctor` | Health-check the roster endpoints and report family/quorum coverage. |

## Portability

Developed and tested on **macOS (Darwin)** and written to run on **Linux** too. Known
platform considerations the code already handles:

- **`timeout(1)`** — not present by default on macOS; the wall-clock guard falls back to
  a portable perl/python implementation (and prefers `gtimeout` if installed).
- **`mktemp`** — BSD (macOS) `mktemp -d` ignores `$TMPDIR` (it uses the Darwin per-user
  temp dir) but still creates valid temp dirs, so the engines work on both. Where
  `$TMPDIR`-routing actually matters (the calibration run's temp cleanup), an explicit
  `"${TMPDIR:-/tmp}/…XXXXXX"` template is used so behavior is consistent across platforms.
- **`date`** — uses `date -u +%Y-%m-%d` (portable across BSD and GNU).
- No reliance on GNU-only flags in the hot paths; JSON handling is done in Python, not
  `sed`/`awk`, to avoid shell-portability traps.
