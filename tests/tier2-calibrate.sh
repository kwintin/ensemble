#!/usr/bin/env bash
# Tier-2: real-CLI calibration smoke (gated/manual — NOT in run-tests.sh).
# Spends real tokens against ONE real reviewer endpoint over the real fixture corpus.
# Usage: bash tests/tier2-calibrate.sh [endpoint-id] [category]
#   e.g. bash tests/tier2-calibrate.sh grok-build@grok injection
# Defaults to the first enabled reviewer and the full corpus.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/roster-path.sh"
source "$ROOT/scripts/lib/roster.sh"

EP="${1:-}"; CAT="${2:-}"
[ -n "$EP" ] || EP="$(ens_reviewers "$ROSTER" | head -1)"
[ -n "$EP" ] || { echo "no enabled reviewer in $ROSTER"; exit 1; }

PASS=0; FAIL=0
pass(){ echo "PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }

echo "== Tier-2 calibrate: roster = $ROSTER, endpoint = $EP, category = ${CAT:-<all>} =="

# capture the user's tree state to assert isolation afterward
before="$(cd "$ROOT" && git status --porcelain 2>/dev/null | sort)"

args=(run --endpoint "$EP"); [ -n "$CAT" ] && args+=(--category "$CAT")
RES="$(mktemp)"
echo "== running real reviews (this spends tokens)... =="
bash "$ROOT/scripts/ens-calibrate.sh" "${args[@]}" > "$RES"; rc=$?
echo "run exit: $rc (0 = something graded, 4 = all skipped)"
echo "--- result ---"; cat "$RES"; echo "--- end result ---"

if [ "$rc" -eq 0 ]; then
  pass "run graded at least one fixture"
  # the endpoint should have at least one scored category
  scored="$(python3 -c "
import json
d=json.load(open('$RES'))
ep=d['ran'][0]
print(sum(1 for c in ep['categories'].values() if c.get('score') is not None))
" 2>/dev/null)"
  [ "${scored:-0}" -ge 1 ] && pass "endpoint has $scored scored categor(y/ies)" || fail "no scored categories"

  echo "== propose (no apply) =="
  bash "$ROOT/scripts/ens-calibrate.sh" propose --result "$RES" > /tmp/.calib-prop.$$ 2>/tmp/.calib-diff.$$ || true
  echo "--- proposed strengths diff ---"; cat /tmp/.calib-diff.$$
  prop="$(python3 -c "import json; print(json.load(open('/tmp/.calib-prop.$$'))['proposed_roster'])" 2>/dev/null)"
  [ -f "$prop" ] && pass "propose wrote a proposed roster ($prop)" || fail "propose produced no roster"
  bash "$ROOT/scripts/ens-setup.sh" validate "$prop" >/dev/null 2>&1 && pass "proposed roster validates" || fail "proposed roster invalid"
  rm -f /tmp/.calib-prop.$$ /tmp/.calib-diff.$$ "$prop" 2>/dev/null
else
  echo "(run exited $rc — skips; not a failure if the CLI was unavailable)"
fi

after="$(cd "$ROOT" && git status --porcelain 2>/dev/null | sort)"
[ "$before" = "$after" ] && pass "user working tree unchanged by calibration" || fail "calibration mutated the user tree"
rm -f "$RES"

echo ""; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
