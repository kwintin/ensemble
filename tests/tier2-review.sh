#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TR="$(mktemp)"
cat > "$TR" <<'J'
{"min_quorum":1,"endpoints":[
  {"id":"gpt-5.5@codex","adapter":"codex","model":"gpt-5.5","family":"openai","effort":"medium","role":"reviewer","structured_output":"json","enabled":true}
]}
J
echo "== Tier-2: real multi-reviewer engine over a planted bug =="
printf 'Review this Python for correctness bugs; list each as file:line - issue.\n\ndef average(xs):\n    return sum(xs)/len(xs)\n' \
  | ENSEMBLE_ROSTER="$TR" "$ROOT/scripts/ens-review.sh" - ; rc=$?
echo "engine exit: $rc (0=quorum met)"
echo "Expected: combined JSON with gpt-5.5@codex status=ok, a CHANGES verdict naming the empty-list/ZeroDivision bug, quorum_met=true, read_only_violation=false."
rm -f "$TR"
