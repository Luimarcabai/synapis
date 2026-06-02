#!/bin/bash
# test-registry-isolation.sh — Sinapsis v4.6.1
# Guards the fix for the registry filename collision: Sinapsis must own
# _sinapsis-projects.json and never read/write the _projects.json filename that
# skill-router / external launchers use. Runtime upsert behaviour is exercised
# end-to-end by tests/test-install-upgrade.sh.

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEARNER="$ROOT/core/_session-learner.sh"
GATHER="$ROOT/core/_eod-gather.sh"

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Match the launcher filename "_projects.json" but NOT "_sinapsis-projects.json".
launcher_ref() { grep -nE "(^|[^-])_projects\.json" "$1" 2>/dev/null; }

echo "=== Sinapsis v4.6.1 Registry Isolation Tests ==="
echo ""

# T1: learner writes the dedicated Sinapsis registry
if grep -q "_sinapsis-projects.json" "$LEARNER"; then
  pass "T1: learner targets _sinapsis-projects.json"
else
  fail "T1: learner should target _sinapsis-projects.json"
fi

# T2: learner does NOT reference the launcher's _projects.json
if launcher_ref "$LEARNER" >/dev/null; then
  fail "T2: learner still references the launcher _projects.json"
else
  pass "T2: learner does not reference _projects.json"
fi

# T3: gather reads the dedicated Sinapsis registry
if grep -q "_sinapsis-projects.json" "$GATHER"; then
  pass "T3: gather reads _sinapsis-projects.json"
else
  fail "T3: gather should read _sinapsis-projects.json"
fi

# T4: no core/ file references the launcher's _projects.json
HITS=0
for f in "$ROOT"/core/*; do
  [ -f "$f" ] || continue
  if launcher_ref "$f" >/dev/null; then
    echo "    offending: $(basename "$f")"
    HITS=$((HITS+1))
  fi
done
if [ "$HITS" -eq 0 ]; then
  pass "T4: no core/ file references the launcher _projects.json"
else
  fail "T4: $HITS core/ file(s) still reference _projects.json"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $((PASS + FAIL))) ==="
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
