#!/bin/bash
# test-plexus-separation.sh — guards the v4.8.0 boundary.
#   The team layer (Sinapsis Plexus) lives in the private team edition since
#   v4.8.0. This public repo must carry NO plexus code in live paths — while
#   history (CHANGELOG, README what's-new) may reference it, and the installer
#   must neither install NOR remove plexus files (they may belong to a
#   team-edition install layered on top). Mirrors test-gstack-separation.sh.
# Run: bash tests/test-plexus-separation.sh

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=8

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo ""
echo "=== Plexus separation tests (v4.8.0 boundary) ==="
echo ""

# T1-T4: the four plexus files are gone
[ ! -f "$SCRIPT_DIR/core/_plexus-sync.sh" ] && pass "T1: core/_plexus-sync.sh removed" \
  || fail "T1: core/_plexus-sync.sh still present"
[ ! -f "$SCRIPT_DIR/commands/plexus.md" ] && pass "T2: commands/plexus.md removed" \
  || fail "T2: commands/plexus.md still present"
[ ! -f "$SCRIPT_DIR/docs/PLEXUS.md" ] && pass "T3: docs/PLEXUS.md removed" \
  || fail "T3: docs/PLEXUS.md still present"
[ ! -f "$SCRIPT_DIR/tests/test-plexus.sh" ] && pass "T4: tests/test-plexus.sh removed" \
  || fail "T4: tests/test-plexus.sh still present"

# T5: installers must not COPY plexus files (but the boundary NOTE mentioning
# them is required — see T7 — so we check copy commands specifically)
if grep -E '^\s*(cp|copy /Y) .*_plexus' "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/install.bat" >/dev/null 2>&1; then
  fail "T5: an installer still copies plexus files"
else
  pass "T5: installers copy no plexus files"
fi

# T6: installers must not REMOVE plexus files either (team edition may own them)
if grep -E '(rm|del).*_plexus' "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/install.bat" >/dev/null 2>&1; then
  fail "T6: an installer deletes plexus files (breaks team-edition installs)"
else
  pass "T6: installers never delete plexus files (team edition may own them)"
fi

# T7: the hands-off policy is documented in both installers
if grep -q "neither installs" "$SCRIPT_DIR/install.sh" && grep -qi "neither installs" "$SCRIPT_DIR/install.bat"; then
  pass "T7: hands-off policy documented in both installers"
else
  fail "T7: hands-off NOTE missing from an installer"
fi

# T8: no core script references plexus (live code paths only)
if grep -rl "plexus" "$SCRIPT_DIR/core" "$SCRIPT_DIR/skills" 2>/dev/null | head -1 | grep -q .; then
  fail "T8: a live core/skills file still references plexus: $(grep -rl 'plexus' "$SCRIPT_DIR/core" "$SCRIPT_DIR/skills" 2>/dev/null | head -2 | tr '\n' ' ')"
else
  pass "T8: no plexus references in core/ or skills/"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED"
[ "$FAIL" -eq 0 ]
