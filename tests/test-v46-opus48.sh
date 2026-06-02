#!/bin/bash
# test-v46-opus48.sh — Sinapsis v4.6 (Opus 4.8 alignment) guard tests
# Asserts the re-tuned caps and that no stale Opus 4.7 model ID lingers.
# Run: bash tests/test-v46-opus48.sh

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTIVATOR="$ROOT/core/_instinct-activator.sh"
LEARNER="$ROOT/core/_session-learner.sh"
RFC="$ROOT/docs/rfc-v5-adaptive-thinking.md"

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== Sinapsis v4.6 Opus 4.8 Alignment Tests ==="
echo ""

# ── Section 1: Caps re-tuned for Opus 4.8 long-context ──
echo "[Section 1] Caps re-tuned for Opus 4.8 long-context"

# T1: TOKEN_BUDGET >= 6000
if grep -qE "TOKEN_BUDGET\s*=\s*[6-9][0-9]{3}" "$ACTIVATOR" 2>/dev/null; then
  pass "T1: TOKEN_BUDGET >= 6000 in activator"
else
  fail "T1: TOKEN_BUDGET should be raised to >= 6000"
fi

# T2: MAX_INSTINCTS_INJECTED >= 8
if grep -qE "MAX_INSTINCTS_INJECTED\s*=\s*[89]" "$ACTIVATOR" 2>/dev/null; then
  pass "T2: MAX_INSTINCTS_INJECTED >= 8"
else
  fail "T2: MAX_INSTINCTS_INJECTED should be raised to >= 8"
fi

# T3: session-learner reads >= 8000 observation lines
if grep -qE "slice\(-[89][0-9]{3}\)|slice\(-[1-9][0-9]{4,}\)" "$LEARNER" 2>/dev/null; then
  pass "T3: session-learner reads >= 8000 observation lines"
else
  fail "T3: learner observation window should be raised to >= 8000"
fi

# ── Section 2: Model ID aligned to claude-opus-4-8 ──
echo ""
echo "[Section 2] Model ID aligned to claude-opus-4-8"

# T4: RFC targets claude-opus-4-8
if grep -q "claude-opus-4-8" "$RFC" 2>/dev/null; then
  pass "T4: RFC references claude-opus-4-8"
else
  fail "T4: RFC should reference claude-opus-4-8"
fi

# T5: no stale claude-opus-4-7 model ID anywhere in docs/
if grep -rq "claude-opus-4-7" "$ROOT/docs" 2>/dev/null; then
  fail "T5: stale claude-opus-4-7 model ID still present in docs/"
else
  pass "T5: no stale claude-opus-4-7 model ID in docs/"
fi

# T6: no stale claude-opus-4-7 model ID in core/
if grep -rq "claude-opus-4-7" "$ROOT/core" 2>/dev/null; then
  fail "T6: stale claude-opus-4-7 model ID still present in core/"
else
  pass "T6: no stale claude-opus-4-7 model ID in core/"
fi

# ── Section 3: Version bumped to v4.6.0 ──
echo ""
echo "[Section 3] Version bumped to v4.6.0"

# T7: README header + badge at v4.6.x (Opus 4.8 line; patches keep the 4.6 minor)
if grep -qE "# Sinapsis v4\.6\.[0-9]" "$ROOT/README.md" 2>/dev/null && grep -qE "version-4\.6\.[0-9]" "$ROOT/README.md" 2>/dev/null; then
  pass "T7: README declares v4.6.x (header + badge)"
else
  fail "T7: README should declare v4.6.x in header and badge"
fi

# T8: CHANGELOG has a v4.6.0 entry
if grep -q "## v4.6.0" "$ROOT/CHANGELOG.md" 2>/dev/null; then
  pass "T8: CHANGELOG has a v4.6.0 entry"
else
  fail "T8: CHANGELOG should have a v4.6.0 entry"
fi

# ── Summary ──
echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $((PASS + FAIL))) ==="
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
