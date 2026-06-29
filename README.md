# Ensemble

Many models, one conductor. Ensemble is a Claude Code plugin that puts a roster of
independent AI model CLIs to work together: dispatched in parallel for consensus
review, or routed by individual strength for delegated coding. Claude stays in charge
the whole way through. It owns the requirements, reconciles what the other models say,
and verifies the result before trusting any of it.

<img src="docs/assets/hero.jpg" alt="Ensemble: a conductor figure in orange directing four jewel-toned model-figures reaching toward a shared point of light" width="820">

## What you get

The thing you configure is a model endpoint: a specific model reached through a
specific CLI, for example `grok-build` via the `grok` binary, or `gpt-5.5` via
`codex`. You build a roster of the endpoints you actually have, and four capabilities
open up inside Claude Code.

### Review

Send a diff, spec, plan, or any document to every healthy reviewer at once. Each one
reviews it independently and read-only, in its own isolated checkout. Claude gathers
the verdicts and reconciles them: agreement across model families is high-confidence,
while a lone dissent gets investigated rather than averaged away. It then drives a
bounded fix-and-re-review loop until the reviewers agree or you call it.

For changes where one model's blind spot would be expensive, council mode adds a
second round. The reviewers see each other's findings with identities stripped,
critique them, and Claude chairs the synthesis. In practice that round is good at two
things: pruning a weak finding that one model over-claimed, and surfacing something the
first pass missed.

### Delegate

Hand a well-scoped unit of work to whichever model your roster rates highest for that
kind of task. It runs write-enabled in a throwaway git worktree on its own branch, so
it never touches your working tree. Claude then verifies the result against an explicit
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
| `agy` | Antigravity (Gemini) | reviewer and executor |
| `grok` | xAI Grok | reviewer and executor |
| `opencode` | OpenCode (DeepSeek and others) | reviewer and executor |
| `kilo` | Kilo (GLM and others) | reviewer and executor |
| `vibe` | Mistral | reviewer only |

## Requirements

- Claude Code, which hosts the plugin.
- `bash`, `python3` (3.8 or newer), and `git` on your `PATH`. The engines are bash with
  small embedded Python, and isolation uses `git worktree`.
- At least one of the supported model CLIs above, installed and signed in.
- Optional: GNU coreutils, for a `timeout`/`gtimeout` binary that gives a sturdier
  wall-clock guard. Without it the engines fall back to a portable perl/python guard. On
  macOS, `brew install coreutils`.

## Install

```bash
/plugin marketplace add kwintin/ensemble
/plugin install ensemble@ensemble-for-claude-code
```

Then build your roster from the CLIs you actually have:

```
/ensemble:setup     detect installed and authenticated CLIs, pick models, write the roster
/ensemble:doctor    check that endpoints are healthy and you have family quorum
```

The roster is written to `$CLAUDE_PLUGIN_DATA/roster.json`, which survives plugin
updates. A shipped default lets the plugin run before you have set anything up.

## Commands

| Command | What it does |
|---------|--------------|
| `/ensemble:review [--council] [--reviewers a,b,c] [scope]` | Multi-model consensus review of a diff, spec, plan, or doc. `--council` runs the de-biased two-round anonymized review with Claude as chairman. |
| `/ensemble:delegate` | Route a well-scoped unit to the strength-matched executor, run it write-enabled in an isolated worktree, and verify against a contract before merging. |
| `/ensemble:calibrate [--endpoint id] [--category cat]` | Measure each reviewer's per-category hit-rate on a fixture corpus and propose grounded `category:score` strengths. |
| `/ensemble:setup` | Detect installed and authenticated CLIs and write a personalized roster. |
| `/ensemble:doctor` | Health-check the roster endpoints and report family and quorum coverage. |

## Safety model

The plugin assumes the other models can and will do surprising things, and contains
them.

- Reviewers run read-only. Each reviewer works inside a disposable git worktree, `cd`'d
  away from your real tree. If a reviewer writes anything, the change is detected and
  the run fails closed rather than quietly touching your code. `codex` is additionally
  held to OS-enforced read-only; the others run in their plan or read-only modes.
- Delegated work is isolated. An executor runs in its own worktree on an
  `ensemble/delegate-*` branch. Nothing reaches your branch until Claude has verified it
  in a clean state, and merges are provenance-guarded so the plugin only ever acts on
  worktrees it created.
- Self-reported success is never trusted. Review verdicts and delegate digests are
  treated as claims, and Claude checks them against the actual tree or the tests before
  acting on them.

## Portability

Developed and tested on macOS (Darwin), and written to run on Linux as well. The code
already handles the usual cross-platform snags:

- `timeout(1)` is not installed by default on macOS, so the wall-clock guard falls back
  to a portable perl/python implementation, preferring `gtimeout` when it is present.
- BSD `mktemp -d` on macOS ignores `$TMPDIR` and uses the Darwin per-user temp dir, but
  it still produces valid temp dirs, so the engines work either way. Where `$TMPDIR`
  routing actually matters, when a calibration run cleans up after itself, the code uses
  an explicit `"${TMPDIR:-/tmp}/...XXXXXX"` template so behavior matches across platforms.
- Dates use `date -u +%Y-%m-%d`, which is portable across BSD and GNU.
- The hot paths avoid GNU-only flags, and JSON is handled in Python rather than `sed` or
  `awk`, to stay clear of shell-portability traps.
