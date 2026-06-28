---
description: Health-check the ensemble roster — verify each enabled endpoint's CLI is installed, authenticated, and wired correctly, and report family/quorum coverage.
argument-hint: ""
---

Run the ensemble doctor. $ARGUMENTS

Run `"$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh"` and report the results: for each enabled endpoint, whether its transport CLI is installed and authenticated (`ok` / `auth` / `missing`) and that its adapter is wired; note the distinct reviewer **families** available (quorum is by family) and warn if fewer than 2 are healthy. If the `timeout`/`gtimeout` note appears, mention the perl/python fallback is in use (suggest `brew install coreutils` on macOS for the robust guard). If an endpoint is `missing` or `auth`, tell the user how to fix it (install / authenticate) or suggest `/ensemble:setup` to reconfigure the roster. A non-zero exit means at least one endpoint is unhealthy.
