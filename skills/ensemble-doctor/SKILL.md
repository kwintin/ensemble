---
name: ensemble-doctor
description: Health-check an Ensemble roster, verify each enabled model CLI is installed and authenticated, and report independent-family quorum coverage. Use when the user asks to diagnose Ensemble, check endpoint health, investigate missing or logged-out transports, or verify readiness after setup.
---

# Ensemble Doctor

## Launcher

Prefer the plugin root the host exports, and fall back to this skill's own location.
Set `SKILL_DIR` to the absolute directory containing this loaded `SKILL.md`, then set:

```bash
ENSEMBLE_ROOT="${ENSEMBLE_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$SKILL_DIR/../.." && pwd)}}}"
ENSEMBLE="$ENSEMBLE_ROOT/scripts/ensemble"
```

Never resolve the launcher from the current working directory.

## Check

Run:

```bash
"$ENSEMBLE" doctor
```

Report each enabled endpoint's health (`ok`, `auth`, or `missing`) and whether its adapter is wired. Relay the `Healthy reviewer families: N (min_quorum M)` summary; quorum counts distinct model families, not transports.

If an endpoint is `missing`, explain that its CLI must be installed or removed from the roster. If it reports `auth`, tell the user to authenticate that CLI and rerun the check. Suggest `ensemble setup` when the roster itself needs reconfiguration. A nonzero exit means at least one endpoint is unhealthy.

If the doctor notes that `timeout` and `gtimeout` are unavailable, explain that the portable fallback is active; on macOS, GNU coreutils provides the more robust timeout path.

Health checks retry non-`ok`, non-`missing` responses because cold transports can briefly look unauthenticated. `ENS_DOCTOR_HEALTH_TRIES` controls attempts per endpoint (default `3`), and `ENS_DOCTOR_RETRY_SLEEP` controls seconds between attempts (default `1`; use `0` in fast local tests). Lower the attempt count only when the user prefers faster failure classification.
