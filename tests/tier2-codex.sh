#!/usr/bin/env bash
# Tier-2: real-codex validation harness (gated/manual — NOT in run-tests.sh).
# Spends real tokens. Run manually: bash tests/tier2-codex.sh
#
# Adaptation from brief (Task 10 requirement):
#   - Fixture committed as plain source files (no nested .git).
#   - Runtime: copies fixture into a mktemp dir, git init + commits there,
#     runs review against that temp repo, asserts read-only, cleans up.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/buggy-repo"

PASS_COUNT=0
FAIL_COUNT=0
fail() { echo "FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
pass() { echo "PASS: $*"; PASS_COUNT=$((PASS_COUNT+1)); }

# ── Section 1: doctor ─────────────────────────────────────────────────────────
echo "== Tier-2: doctor =="
bash "$ROOT/scripts/doctor.sh" && doctor_rc=0 || doctor_rc=$?
if [ "$doctor_rc" -eq 0 ]; then
  pass "doctor exited 0 (all endpoints healthy)"
else
  fail "doctor exited $doctor_rc"
fi

# ── Section 2: set up throwaway git repo ──────────────────────────────────────
echo ""
echo "== Tier-2: setting up throwaway git repo =="
TMPDIR_REPO="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_REPO"' EXIT

cp "$FIX/calc.py" "$TMPDIR_REPO/calc.py"
git -C "$TMPDIR_REPO" init -q
git -C "$TMPDIR_REPO" config user.email "tier2-test@ensemble"
git -C "$TMPDIR_REPO" config user.name "tier2-test"
git -C "$TMPDIR_REPO" add calc.py
git -C "$TMPDIR_REPO" commit -q -m "fixture"
before_head="$(git -C "$TMPDIR_REPO" rev-parse HEAD)"
echo "  temp repo: $TMPDIR_REPO ($(git -C "$TMPDIR_REPO" rev-parse --short HEAD))"

# ── Section 3: real codex review of planted bug ───────────────────────────────
echo ""
echo "== Tier-2: real codex review of planted bug =="
REVIEW_OUT="$(mktemp)"
trap 'rm -rf "$TMPDIR_REPO"; rm -f "$REVIEW_OUT"' EXIT

PROMPT="$(printf 'Review this file for correctness bugs. List each as file:line - issue.\n\n%s' "$(cat "$FIX/calc.py")")"

printf '%s' "$PROMPT" \
  | bash "$ROOT/scripts/model-cli.sh" review --endpoint gpt-5.5@codex - \
  > "$REVIEW_OUT" 2>&1 && review_rc=0 || review_rc=$?

echo "--- review output ---"
cat "$REVIEW_OUT"
echo "--- end review output ---"

if [ "$review_rc" -eq 0 ]; then
  pass "model-cli review exited 0"
else
  fail "model-cli review exited $review_rc"
fi

# Check verdict is parseable (non-ERROR).
# model-cli outputs the raw adapter JSON line (from codex stdout) followed by
# the normalized envelope from ens_normalize_verdict.  Scan all lines and pick
# the first that has a non-ERROR "verdict" key, or the last parseable one.
verdict="$(python3 -c "
import json, sys
text = open('$REVIEW_OUT').read()
best = 'PARSE_ERROR'
# Try whole text first (covers single-object case)
try:
    d = json.loads(text)
    v = d.get('verdict', 'ERROR')
    if v != 'ERROR': best = v; raise SystemExit(0)
except (json.JSONDecodeError, SystemExit): pass
# Try line by line
for line in text.splitlines():
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        v = d.get('verdict', 'ERROR')
        if v in ('APPROVED','CHANGES'): best = v
    except Exception: pass
print(best)
" 2>/dev/null)"
echo "  verdict: $verdict"
if [ "$verdict" = "CHANGES" ] || [ "$verdict" = "APPROVED" ]; then
  pass "verdict is parseable ($verdict)"
else
  fail "verdict not parseable (got: $verdict)"
fi

# Check that the bug is named (average / empty list / ZeroDivisionError)
if grep -qi "zero\|empty\|average\|len\|division" "$REVIEW_OUT"; then
  pass "review names the average/empty-list bug"
else
  fail "review does NOT name the bug (see output above)"
fi

# ── Section 4: read-only assertion ────────────────────────────────────────────
echo ""
echo "== Tier-2: read-only assertion (temp repo) =="
dirty="$(git -C "$TMPDIR_REPO" status --porcelain)"
if [ -z "$dirty" ]; then
  pass "working tree unchanged (codex did not mutate temp repo)"
else
  fail "codex mutated the temp repo tree: $dirty"
fi
after_head="$(git -C "$TMPDIR_REPO" rev-parse HEAD)"
[ "$before_head" = "$after_head" ] && pass "HEAD unchanged" || fail "HEAD changed"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
