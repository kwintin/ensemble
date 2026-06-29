---
description: Health-check the ensemble roster — verify each enabled endpoint's CLI is installed, authenticated, and wired correctly, and report family/quorum coverage.
argument-hint: ""
---

Run the ensemble doctor. $ARGUMENTS

Run `"$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh"` and report the results: for each enabled endpoint, whether its transport CLI is installed and authenticated (`ok` / `auth` / `missing`) and that its adapter is wired. The script prints a `Healthy reviewer families: N (min_quorum M)` line (quorum is by model family) and warns when `N` is below the roster's `min_quorum` — relay that. If the `timeout`/`gtimeout` note appears, mention the perl/python fallback is in use (suggest `brew install coreutils` on macOS for the robust guard). If an endpoint is `missing` or `auth`, tell the user how to fix it (install / authenticate) or suggest `/ensemble:setup` to reconfigure the roster. A non-zero exit means at least one endpoint is unhealthy.

Some transport CLIs (notably `agy` and `grok`) **flap**: their health probe intermittently reports a sign-in error even while authenticated, and a cold probe can take 8–15s. The doctor therefore retries a non-`ok`, non-`missing` verdict before reporting it, so a single flap is not mistaken for a logout. Tunable via env vars: `ENS_DOCTOR_HEALTH_TRIES` (attempts per endpoint, default `3`) and `ENS_DOCTOR_RETRY_SLEEP` (seconds between attempts, default `1`; set `0` to disable). A genuinely down endpoint is still reported `auth`/`missing` (retry never masks a real failure) but takes up to ~`20s × tries` to classify; lower `ENS_DOCTOR_HEALTH_TRIES` for faster CI checks.
