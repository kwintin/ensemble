---
name: ensemble-setup
description: Interactive setup wizard for the ensemble plugin — detect which model CLIs are installed and authenticated, let the user pick which models to enable per transport, tag family/role/strengths, and write a personalized roster. Use for /ensemble:setup or when the user wants to (re)configure their ensemble reviewers/executors.
---

# Ensemble Setup Wizard

You are the wizard engine (a self-configuring wizard): ask the questions, the scripts do the detection. Re-runnable anytime. Result persists to a single **target path** — `$CLAUDE_PLUGIN_DATA/roster.json` if `$CLAUDE_PLUGIN_DATA` is set (survives plugin updates; the engines prefer it over the shipped default), else `$CLAUDE_PLUGIN_ROOT/roster.json`. Compute that target once and use it for BOTH the write and the validate.

## The flow
1. **Detect.** Run the detector and parse its JSON:
   ```bash
   "$CLAUDE_PLUGIN_ROOT/scripts/ens-setup.sh" detect
   ```
   Output: `{adapters:[{adapter, health(ok|auth|missing), executor_capable, structured_output, default_role, model_count, models[]}]}`.
   - `missing` → tell the user it's not installed (skip it).
   - `auth` → tell them it's installed but not logged in (skip, suggest authenticating then re-run).
   - `ok` → it's a candidate; continue.

2. **Pick models per transport.** For each `ok` transport, ask which models to enable (AskUserQuestion, multiSelect). Each pick becomes an endpoint `model@adapter`.
   - For huge catalogs (opencode/kilo, hundreds of models): do NOT dump all of them. Offer a **shortlist spanning distinct families** (use the next step's `family` helper to pick a handful of different vendors) plus an "Other — type the exact id" path. The user can name any id from `models[]`.
   - Surface effort/active-alias where relevant.

3. **Tag each chosen endpoint.** For every selected `model`:
   - **id** (must be engine-safe — model ids with slashes/spaces are rejected by the engines): `ens-setup.sh idfor "<model>" <adapter>` → e.g. `deepseek-v4-pro@opencode`. The full model id stays in the `model` field.
   - **family** (diversity is by family — get this right): `ens-setup.sh family "<model>"`. Show it; let the user correct it (the SAME model via two transports is ONE family). Never leave it `unknown` — ask.
   - **role**: default from `default_role` (vibe → `reviewer`; write-capable transports → `both`). Let the user choose `reviewer | executor | both`. Only executor-capable transports may be `executor`/`both`.
   - **strengths + latency**: seed from `ens-setup.sh defaults "<model>"` (it resolves the family, so sub-brands like `devstral`/`opus` seed correctly); let the user accept or tweak (refined later via `/ensemble:calibrate`).
   - **effort**: default `medium` (codex/grok honor it; others ignore it). **structured_output**: `json` for codex, `sentinel` for every other adapter (validate enforces this). **read_only_mode** (informational): `sandbox-read-only` (codex), `permission-mode-plan` (grok), `max-turns-1` (vibe), `sandbox+worktree` (agy), `directive+worktree` (opencode/kilo).

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
   "$CLAUDE_PLUGIN_ROOT/scripts/ens-setup.sh" validate "<target path>"
   ```
   Fix anything it reports (it enforces engine-safe ids, a present `model`, executor-capability, and the structured_output pairing). Finally, suggest `/ensemble:doctor` to confirm the live roster is healthy.

## Rules
- One endpoint per (model, transport) pick; the `id` is the engine-safe `idfor` output, NOT the raw `model@adapter` (router model ids contain slashes the engines reject).
- `min_quorum` defaults to 2 (review proceeds once ≥2 distinct OK families respond); set 1 only if the user enables a single family.
- Don't invent models — only offer ids from `detect`'s `models[]` (or an exact id the user types).
- Re-running is safe and expected; it rewrites the personalized roster.
