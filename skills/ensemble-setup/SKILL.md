---
name: ensemble-setup
description: Configure Ensemble interactively — detect installed and authenticated model CLIs, let the user pick models per transport, tag family, role, and strengths, then write a personalized roster. Use for Ensemble setup or whenever the user wants to configure or reconfigure reviewers and executors.
---

# Ensemble Setup Wizard

Ask the questions; let the launcher do deterministic detection and validation. Setup is safe to re-run.

## Launcher and target

Prefer the plugin root the host exports, and fall back to this skill's own location.
Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md`, then set:

```bash
ENSEMBLE_ROOT="${ENSEMBLE_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$SKILL_DIR/../.." && pwd)}}}"
ENSEMBLE="$ENSEMBLE_ROOT/scripts/ensemble"
DATA_DIR="${ENSEMBLE_DATA_DIR:-${PLUGIN_DATA:-${CLAUDE_PLUGIN_DATA:-${CODEX_HOME:-${HOME:?set ENSEMBLE_DATA_DIR when HOME and CODEX_HOME are unavailable}/.codex}/plugins/data/ensemble}}}"
TARGET="${ENSEMBLE_ROSTER:-$DATA_DIR/roster.json}"
```

Never resolve the launcher from the current working directory. Compute `TARGET` once and use it for both writing and validation. The data directory survives versioned plugin updates.

## The flow
1. **Detect.** Run the detector and parse its JSON:
   ```bash
   "$ENSEMBLE" setup detect
   ```
   Output: `{adapters:[{adapter, health(ok|auth|missing), executor_capable, structured_output, default_role, model_count, models[]}]}`.
   - `missing` → tell the user it's not installed (skip it).
   - `auth` → tell them it's installed but not logged in (skip, suggest authenticating then re-run).
   - `ok` → it's a candidate; continue.

2. **Pick models per transport.** For each `ok` transport, ask which models to enable; offer a concise multi-selection when the interface supports it. Each pick becomes an endpoint `model@adapter`.
   - For huge catalogs (opencode/kilo, hundreds of models): do NOT dump all of them. Offer a **shortlist spanning distinct families** (use the next step's `family` helper to pick a handful of different vendors) plus an "Other — type the exact id" path. The user can name any id from `models[]`.
   - Surface effort/active-alias where relevant.

3. **Tag each chosen endpoint.** For every selected `model`:
   - **id** (must be engine-safe — model ids with slashes/spaces are rejected by the engines): `"$ENSEMBLE" setup idfor "<model>" <adapter>` → e.g. `deepseek-v4-pro@opencode`. The full model id stays in the `model` field.
   - **family** (diversity is by family — get this right): `"$ENSEMBLE" setup family "<model>"`. Show it; let the user correct it (the SAME model via two transports is ONE family). Never leave it `unknown` — ask.
   - **role**: default from `default_role` (vibe → `reviewer`; write-capable transports → `both`). Let the user choose `reviewer | executor | both`. Only executor-capable transports may be `executor`/`both`.
   - **strengths + latency**: seed from `"$ENSEMBLE" setup defaults "<model>"` (it resolves the family, so sub-brands like `devstral`/`opus` seed correctly); let the user accept or tweak (refined later via `ensemble calibrate`).
   - **effort**: default `medium` (some transports honor it; others ignore it). **structured_output**: use the adapter's value from `detect`; validation enforces the pairing. **read_only_mode** (informational): record the adapter's enforced review mode, such as `sandbox-read-only`, `permission-mode-plan`, `max-turns-1`, or worktree-backed directive mode.

4. **Diversity check.** If two *enabled* endpoints share a `family`, warn the user ("same model = one opinion; counts once toward quorum") and let them drop or keep one.

5. **Write + validate.** Assemble the roster and write it to the target path from the header (create the dir). Shape:
   ```json
   { "reviewers_default": ["<enabled reviewer endpoint ids>"], "min_quorum": 2,
     "endpoints": [ { "id":"<engine-safe id>", "adapter":"…", "model":"<full model id>", "family":"…",
       "effort":"medium", "role":"…", "read_only_mode":"…", "structured_output":"…",
       "strengths":[…], "latency_tier":"…", "enabled":true } ] }
   ```
   Then validate the SAME target path:
   ```bash
   "$ENSEMBLE" setup validate "$TARGET"
   ```
   Fix anything it reports (it enforces engine-safe ids, a present `model`, executor-capability, and the structured-output pairing). Finally, suggest `ensemble doctor` to confirm the live roster is healthy.

## Rules
- One endpoint per (model, transport) pick; the `id` is the engine-safe `idfor` output, NOT the raw `model@adapter` (router model ids contain slashes the engines reject).
- `min_quorum` defaults to 2 (review proceeds once ≥2 distinct OK families respond); set 1 only if the user enables a single family.
- Don't invent models — only offer ids from `detect`'s `models[]` (or an exact id the user types).
- Re-running is safe and expected; it rewrites the personalized roster.
