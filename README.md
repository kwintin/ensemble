# Ensemble

Many models, one conductor. Ensemble is a local Claude Code and Codex plugin that puts
a roster of independent AI model CLIs to work together: dispatched in parallel for
consensus review, or routed by individual strength for delegated coding. Whichever host
you invoke Ensemble from stays in charge. It owns the requirements, reconciles what the
other models say, and verifies the result before trusting any of it.

<img src="docs/assets/hero.jpg" alt="Ensemble: a conductor figure in orange directing four jewel-toned model-figures reaching toward a shared point of light" width="820">

## What you get

The thing you configure is a model endpoint: a specific model reached through a
specific CLI, for example `sonnet` via the `claude` binary, `grok-build` via `grok`,
or `gpt-5.5` via `codex`. You build a roster of the endpoints you actually have, and
four capabilities open up inside the host agent.

### Review

Send a diff, spec, plan, or any document to every healthy reviewer at once. Each one
reviews it independently and read-only, in its own isolated checkout. The conductor
gathers the verdicts and reconciles them: agreement across model families is
high-confidence, while a lone dissent gets investigated rather than averaged away. It
then drives a bounded fix-and-re-review loop until the reviewers agree or you call it.

For changes where one model's blind spot would be expensive, council mode adds a
second round. The reviewers see each other's findings with identities stripped,
critique them, and the conductor chairs the synthesis. In practice that round is good at two
things: pruning a weak finding that one model over-claimed, and surfacing something the
first pass missed.

### Delegate

Hand a well-scoped unit of work to whichever model your roster rates highest for that
kind of task. It runs write-enabled in a throwaway git worktree on its own branch, so
it never touches your working tree. The conductor then verifies the result against an explicit
contract, in a clean checkout, before anything merges. A model reporting "done" does
not count on its own; the change has to actually pass.

### Calibrate

Delegate's routing leans on each model's `strengths`, so rather than assert those from
a vendor card, calibrate measures them. It runs a category-tagged corpus of small
fixtures through each reviewer's real review path, scores how often each one finds the
planted bug per category, and proposes a roster rewrite carrying the measured
`category:score` tags for you to accept or reject. The result is a prior you can
defend, "measured on my fixtures, through my CLIs," not a number off a leaderboard.

### Provenance

Every dispatch announces which CLI, model, and family is being asked to do what, and
what came back:

```
▶ review   deepseek-v4-pro@opencode · cli=opencode · model=deepseek-v4-pro · family=deepseek
◀ deepseek-v4-pro@opencode → APPROVED
▶ delegate grok-build@grok · cli=grok · model=grok-build · family=xai · routed: payment-logic
◀ grok-build@grok → ok
```

So when "the ensemble" hands you a verdict, you can always trace which model produced
it and, for delegated work, why that model was chosen. Set `ENSEMBLE_PROVENANCE=0` to
silence the lines.

## Independence is counted by family

Consensus is only worth something if the voices are genuinely independent. If two
endpoints on your roster are the same underlying model behind different CLIs, they give
you one opinion twice, not two opinions. Ensemble therefore tracks independence and
quorum by model family, so a roster with two OpenAI-backed endpoints still contributes
a single OpenAI vote toward quorum. The same key drives delegation: strengths are weak
priors, and family diversity does the real work.

## The models it speaks to

You do not need all of these. The roster adapts to whatever you have installed and
authenticated, and one CLI is enough to start.

| CLI | Transport / model | Roles |
|-----|-------------------|-------|
| `codex` | OpenAI Codex | reviewer and executor (OS-sandboxed read-only or workspace-write) |
| `claude` | Anthropic Claude Code | reviewer and executor (safe mode; plan mode for review; native Bash sandbox plus an isolated worktree for writes) |
| `agy` | Antigravity (Gemini) | reviewer and executor |
| `grok` | xAI Grok | reviewer and executor |
| `opencode` | OpenCode (DeepSeek and others) | reviewer and executor |
| `kilo` | Kilo (GLM and others) | reviewer and executor |
| `vibe` | Mistral | reviewer only |

## Requirements

- Claude Code or local Codex, which hosts the plugin.
- `bash`, `python3` (3.8 or newer), and `git` on your `PATH`. The engines are bash with
  small embedded Python, and isolation uses `git worktree`.
- At least one of the supported model CLIs above, installed and signed in.
- Optional: GNU coreutils, for a `timeout`/`gtimeout` binary that gives a sturdier
  wall-clock guard. Without it the engines fall back to a portable perl/python guard. On
  macOS, `brew install coreutils`.

## Install

### Claude Code

```bash
/plugin marketplace add kwintin/ensemble
/plugin install ensemble@ensemble-for-claude-code
```

### Codex (local development)

From this repository, register the local marketplace and install its current contents:

```bash
codex plugin marketplace add /absolute/path/to/ensemble
codex plugin add ensemble@ensemble-for-claude-code
```

After installing or reinstalling, start a new Codex thread so it loads the plugin's
skills. Run `/hooks` once to review and trust the current Ensemble hook hash; Codex
keeps the optional SessionStart/PostToolUse reminders disabled until you approve it.

Then build your roster from the CLIs you actually have:

In Claude Code, run `/ensemble:setup` and `/ensemble:doctor`. In Codex, invoke
`$ensemble:ensemble-setup` and `$ensemble:ensemble-doctor` (or ask Ensemble to set up
or diagnose the roster in plain language).

The roster is written to the host's persistent plugin data directory, which survives
plugin updates. Set `ENSEMBLE_DATA_DIR` or `ENSEMBLE_ROSTER` to override it. A shipped
default lets the plugin run before you have set anything up.

Every endpoint carries an `enabled` flag, so you can take one out of the panel without
losing its configuration: set `"enabled": false` in the roster, or deselect it the next
time you run setup. That is worth knowing for `sonnet@claude`, which ships enabled. When
Codex hosts the plugin it is a genuinely independent family; when Claude Code hosts it,
that reviewer is the same family as the conductor, so it contributes another opinion
rather than an independent one. Quorum counts families, so it is never double-counted
either way — disable it if you would rather not spend the call.

## Commands

| Workflow | Claude Code | Codex |
|----------|-------------|-------|
| Review | `/ensemble:review` | `$ensemble:multi-model-review` |
| Delegate | `/ensemble:delegate` | `$ensemble:delegate-implementation` |
| Calibrate | `/ensemble:calibrate` | `$ensemble:ensemble-calibrate` |
| Setup | `/ensemble:setup` | `$ensemble:ensemble-setup` |
| Doctor | `/ensemble:doctor` | `$ensemble:ensemble-doctor` |

Review accepts `--council`, `--reviewers a,b,c`, `--keep-work`, and an optional scope.
The other workflows preserve the same setup, delegation, calibration, and health-check
behavior on both hosts.

## Tuning and recovery

The engines carry two free-text fields into the conductor's context: a reviewer's prose
and a failed executor's stderr. Both are capped so a fan-out of reviewers cannot flood
that context — but a cap that trims silently is worse than a large one, because a
sentinel reviewer's prose *is* its review (its `findings[]` is empty by construction),
so a quiet trim reads as findings that were never made.

| Knob | Default | Effect |
|------|---------|--------|
| `ENSEMBLE_REVIEW_CAP` | `20000` | Characters of reviewer prose kept in `reviewers[].review`. `0` = uncapped. |
| `ENSEMBLE_STDERR_CAP` | `2000` | Characters of executor stderr kept in a delegate result. `0` = uncapped. |
| `ENSEMBLE_PROVENANCE` | on | Set to `0` to silence the `▶`/`◀` dispatch lines. |
| `--keep-work` | off | On `review` and `council`: keep the run's work directory and print its path to stderr. |

Neither cap is ever applied silently. When one bites, the record gains
`review_truncated` / `review_chars` (or `stderr_truncated` / `stderr_chars`) alongside
the trimmed text, and review warns on stderr naming the endpoint and both lengths. A
malformed value falls back to the default with a warning rather than producing a
nonsense slice.

`--keep-work` is the recovery path: the untrimmed reviewer text lives in the run's work
directory as `<endpoint>.out`, which is otherwise deleted when the run exits. Council
propagates the flag to both of its rounds, so the round-1 prose behind an anonymized
peer block is recoverable too. The disposable review worktree is still torn down either
way, since it is registered with your repo and leaving it behind would dirty real state.

## Safety model

The plugin assumes the other models can and will do surprising things, and contains
them.

- Reviewers run read-only. Each reviewer works inside a disposable git worktree, `cd`'d
  away from your real tree. If a reviewer writes anything, the change is detected and
  the run fails closed rather than quietly touching your code. `codex` is additionally
  held to OS-enforced read-only; the others run in their plan or read-only modes.
- Delegated work is isolated. An executor runs in its own worktree on an
  `ensemble/delegate-*` branch. Nothing reaches your branch until the conductor has verified it
  in a clean state, and merges are provenance-guarded so the plugin only ever acts on
  worktrees it created.
- Self-reported success is never trusted. Review verdicts and delegate digests are
  treated as claims, and the conductor checks them against the actual tree or the tests before
  acting on them.

## Portability

Developed and tested on macOS (Darwin), and written to run on Linux as well. The code
already handles the usual cross-platform snags:

- `timeout(1)` is not installed by default on macOS, so the wall-clock guard falls back
  to a portable perl/python implementation, preferring `gtimeout` when it is present.
  The guard also self-checks its backend before use: `timeout(1)` and the perl path are
  both driven by `alarm(2)` timers, and a host whose timers do not fire makes them run
  the child to completion and return its exit status instead of failing — a guard that
  silently does nothing. A backend that fails to interrupt a live child is skipped in
  favour of the timerless python3 path, and `doctor` reports which one is in use.
- BSD `mktemp -d` on macOS ignores `$TMPDIR` and uses the Darwin per-user temp dir, but
  it still produces valid temp dirs, so the engines work either way. Where `$TMPDIR`
  routing actually matters, when a calibration run cleans up after itself, the code uses
  an explicit `"${TMPDIR:-/tmp}/...XXXXXX"` template so behavior matches across platforms.
- Dates use `date -u +%Y-%m-%d`, which is portable across BSD and GNU.
- The hot paths avoid GNU-only flags, and JSON is handled in Python rather than `sed` or
  `awk`, to stay clear of shell-portability traps.
