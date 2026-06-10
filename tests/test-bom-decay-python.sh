#!/bin/bash
# test-bom-decay-python.sh — regression tests for the v4.6.2 audit fixes
#   Section 1: UTF-8 BOM tolerance in JSON readers (#16)
#   Section 2: confidence-decay demotions persisted on the no-match path
#   Section 3: Windows-safe Python detection (Store shim, aligned with PR #24)
# Run: bash tests/test-bom-decay-python.sh

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACTIVATOR="$SCRIPT_DIR/core/_instinct-activator.sh"
PASSIVE="$SCRIPT_DIR/core/_passive-activator.sh"
OBSERVE="$SCRIPT_DIR/skills/sinapsis-learning/hooks/observe.sh"
INSTALL="$SCRIPT_DIR/install.sh"

PASS=0
FAIL=0
TOTAL=12

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.claude/skills"
}

teardown_sandbox() {
  rm -rf "$SANDBOX" 2>/dev/null
}

# Prepend a UTF-8 BOM (EF BB BF) to a file in place
add_bom() {
  printf '\xef\xbb\xbf' > "$1.bom"
  cat "$1" >> "$1.bom"
  mv "$1.bom" "$1"
}

echo ""
echo "=== v4.6.2 regression tests: BOM, decay persistence, Python detection ==="
echo ""

# ── Section 1: UTF-8 BOM tolerance (#16) ──
echo "[Section 1] UTF-8 BOM in JSON readers"

setup_sandbox
INDEX="$SANDBOX/.claude/skills/_instincts-index.json"
cat > "$INDEX" << 'EOFIDX'
{
  "version": "4.1",
  "instincts": [
    {"id":"bom-rule","domain":"general","level":"confirmed","trigger_pattern":"Edit","inject":"BOM survivor rule","occurrences":5,"first_triggered":"2026-04-01T00:00:00Z","last_triggered":"2026-06-01T00:00:00Z"}
  ],
  "archived": []
}
EOFIDX
add_bom "$INDEX"

INPUT='{"tool_name":"Edit","tool_input":{"file_path":"x.js"}}'
OUT=$(echo "$INPUT" | HOME="$SANDBOX" bash "$ACTIVATOR" 2>/dev/null)

# T1: activator still injects when the index carries a BOM
if echo "$OUT" | grep -q "BOM survivor rule"; then
  pass "T1: Activator injects instinct from BOM-prefixed index"
else
  fail "T1: BOM-prefixed index silenced the activator. OUT='$OUT'"
fi

# T2: occurrence tracking incremented and persisted despite the BOM
if grep -q '"occurrences": 6' "$INDEX" 2>/dev/null; then
  pass "T2: Occurrences incremented (5 -> 6) in BOM-prefixed index"
else
  fail "T2: Occurrences not persisted — BOM read failed silently"
fi
teardown_sandbox

# T3: BOM strip replicated in every core JSON reader
MISSING=""
for f in _instinct-activator.sh _session-learner.sh _dream.sh _eod-gather.sh _passive-activator.sh _project-context.sh; do
  grep -q "0xFEFF" "$SCRIPT_DIR/core/$f" 2>/dev/null || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
  pass "T3: BOM strip present in all 6 core readers"
else
  fail "T3: BOM strip missing in:$MISSING"
fi

# T4: dashboard generator reads JSON with utf-8-sig
if grep -q "utf-8-sig" "$SCRIPT_DIR/core/_generate-dashboard.py" 2>/dev/null; then
  pass "T4: _generate-dashboard.py uses utf-8-sig"
else
  fail "T4: _generate-dashboard.py must read JSON with encoding='utf-8-sig'"
fi

# T5: passive-activator functional — BOM-prefixed rules file still fires
setup_sandbox
RULES="$SANDBOX/.claude/skills/_passive-rules.json"
cat > "$RULES" << 'EOFRULES'
{"rules":[{"id":"r1","trigger":"Edit","inject":"BOM passive rule fired"}]}
EOFRULES
add_bom "$RULES"
OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"x.js"}}' | HOME="$SANDBOX" bash "$PASSIVE" 2>/dev/null)
if echo "$OUT" | grep -q "BOM passive rule fired"; then
  pass "T5: Passive activator injects rule from BOM-prefixed rules file"
else
  fail "T5: BOM-prefixed rules file silenced the passive activator. OUT='$OUT'"
fi
teardown_sandbox

# ── Section 2: decay persistence on the no-match path ──
echo ""
echo "[Section 2] Confidence decay persisted when nothing matches"

# T6: stale confirmed instinct demoted to draft even though the tool use matches nothing
setup_sandbox
INDEX="$SANDBOX/.claude/skills/_instincts-index.json"
cat > "$INDEX" << 'EOFIDX'
{
  "version": "4.1",
  "instincts": [
    {"id":"stale-confirmed","domain":"general","level":"confirmed","trigger_pattern":"ZZZNEVERMATCH","inject":"stale rule","occurrences":5,"first_triggered":"2025-01-01T00:00:00Z","last_triggered":"2025-01-01T00:00:00Z"}
  ],
  "archived": []
}
EOFIDX
echo '{"tool_name":"Read","tool_input":{"file_path":"x.js"}}' | HOME="$SANDBOX" bash "$ACTIVATOR" >/dev/null 2>&1
if grep -q '"level": "draft"' "$INDEX" 2>/dev/null; then
  pass "T6: Stale confirmed instinct persisted as draft on no-match tool use"
else
  fail "T6: Demotion discarded — index still has: $(grep -o '"level": "[a-z]*"' "$INDEX" 2>/dev/null | head -1)"
fi
teardown_sandbox

# T7: stale draft instinct archived (filtered out of the index) on no-match tool use
setup_sandbox
INDEX="$SANDBOX/.claude/skills/_instincts-index.json"
cat > "$INDEX" << 'EOFIDX'
{
  "version": "4.1",
  "instincts": [
    {"id":"stale-draft","domain":"general","level":"draft","trigger_pattern":"ZZZNEVERMATCH","inject":"stale draft rule","occurrences":1,"first_triggered":"2025-01-01T00:00:00Z","last_triggered":"2025-01-01T00:00:00Z"}
  ],
  "archived": []
}
EOFIDX
echo '{"tool_name":"Read","tool_input":{"file_path":"x.js"}}' | HOME="$SANDBOX" bash "$ACTIVATOR" >/dev/null 2>&1
if ! grep -q 'stale-draft' "$INDEX" 2>/dev/null && grep -q '"version"' "$INDEX" 2>/dev/null; then
  pass "T7: Stale draft instinct archived out of index on no-match tool use"
else
  fail "T7: Stale draft instinct still present after decay window"
fi
teardown_sandbox

# T8: fresh instinct + no match = no write (decay must not cause spurious rewrites)
setup_sandbox
INDEX="$SANDBOX/.claude/skills/_instincts-index.json"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$INDEX" << EOFIDX
{
  "version": "4.1",
  "instincts": [
    {"id":"fresh-confirmed","domain":"general","level":"confirmed","trigger_pattern":"ZZZNEVERMATCH","inject":"fresh rule","occurrences":5,"first_triggered":"$NOW","last_triggered":"$NOW"}
  ],
  "archived": []
}
EOFIDX
BEFORE=$(cat "$INDEX")
echo '{"tool_name":"Read","tool_input":{"file_path":"x.js"}}' | HOME="$SANDBOX" bash "$ACTIVATOR" >/dev/null 2>&1
AFTER=$(cat "$INDEX")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "T8: Fresh instinct untouched — no spurious index rewrite on no-match"
else
  fail "T8: Index rewritten without dirty or decay state"
fi
teardown_sandbox

# ── Section 3: Windows-safe Python detection (PR #24 alignment) ──
echo ""
echo "[Section 3] Python detection validates --version (Store shim)"

# T9: observe.sh validates candidates with --version
if grep -qE 'Python 3\\\.' "$OBSERVE" 2>/dev/null && grep -q '"py -3"' "$OBSERVE" 2>/dev/null; then
  pass "T9: observe.sh iterates candidates and validates --version output"
else
  fail "T9: observe.sh must validate Python candidates with --version (py -3 first)"
fi

# T10: install.sh validates candidates with --version
if grep -qE 'Python 3\\\.' "$INSTALL" 2>/dev/null && grep -q '"py -3"' "$INSTALL" 2>/dev/null; then
  pass "T10: install.sh iterates candidates and validates --version output"
else
  fail "T10: install.sh must validate Python candidates with --version (py -3 first)"
fi

# T11: install.sh guards the version echo against set -e (stray shim exits non-zero)
if grep -q -- '--version 2>&1 || true' "$INSTALL" 2>/dev/null; then
  pass "T11: install.sh version echo guarded with || true under set -e"
else
  fail "T11: PYTHON_VER=\$(\$PYTHON_CMD --version) must be guarded with || true"
fi

# T12: functional — a Store-shim-like python3 (answers command -v, fails --version)
# is skipped, and the next candidate that really reports Python 3.x is executed.
# The fake reports 3.14.0 on purpose: pinned-minor regexes (3.9-3.13) must not reject it.
setup_sandbox
FAKEBIN="$SANDBOX/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/python3" << 'EOFSHIM'
#!/bin/bash
echo "Python was not found; run without arguments to install from the Microsoft Store" >&2
exit 9
EOFSHIM
cat > "$FAKEBIN/python" << EOFREAL
#!/bin/bash
if [ "\$1" = "--version" ]; then echo "Python 3.14.0"; exit 0; fi
touch "$SANDBOX/observer-ran"
exit 0
EOFREAL
chmod +x "$FAKEBIN/python3" "$FAKEBIN/python"
# Restricted PATH: fake bin + core unix tools only, so the real `py`/`python3` are invisible
echo '{"tool_name":"Edit"}' | HOME="$SANDBOX" PATH="$FAKEBIN:/usr/bin:/bin" bash "$OBSERVE" post >/dev/null 2>&1
if [ -f "$SANDBOX/observer-ran" ]; then
  pass "T12: Shim python3 skipped, valid python executed the observer"
else
  fail "T12: Detection accepted the shim (or found no interpreter) — observer never ran"
fi
teardown_sandbox

# ── Summary ──
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
