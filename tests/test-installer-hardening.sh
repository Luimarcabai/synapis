#!/bin/bash
# ============================================================
# TDD Tests: installer hardening (iAmasters OS audit, 2026-07-17)
# #1 hooks must be wired into an EXISTING settings.json (deep-merge)
# #2 legacy cleanup must archive, never delete
# #3 install.bat must copy skill subdirs, use !errorlevel!, drop wmic
# #5 version consistency between CHANGELOG, installers and README
# ============================================================

set -e

PASS=0
FAIL=0
TESTS=0

pass() { PASS=$((PASS + 1)); TESTS=$((TESTS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); TESTS=$((TESTS + 1)); echo "  FAIL: $1"; }

SANDBOX=""
cleanup() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT

SANDBOX=$(mktemp -d)
FAKE_HOME="$SANDBOX/home"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MERGE="$SCRIPT_DIR/core/_merge-hooks.js"
TEMPLATE="$SCRIPT_DIR/core/settings.template.json"

echo "=== Installer Hardening Tests ==="
echo "Sandbox: $SANDBOX"
echo ""

# Sinapsis hook commands expected after wiring (from settings.template.json)
count_sinapsis_hooks() {
  # $1 = settings file; prints how many of the 7 template commands are present
  node -e '
const fs = require("fs");
let raw = fs.readFileSync(process.argv[1], "utf8");
if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
const s = JSON.parse(raw);
const cmds = [];
for (const groups of Object.values(s.hooks || {}))
  for (const g of groups)
    for (const h of (g.hooks || []))
      if (typeof h.command === "string") cmds.push(h.command.trim());
const expected = [
  "bash ~/.claude/skills/sinapsis-learning/hooks/observe.sh pre",
  "bash ~/.claude/skills/_project-context.sh",
  "bash ~/.claude/skills/_passive-activator.sh",
  "bash ~/.claude/skills/_instinct-activator.sh",
  "bash ~/.claude/skills/sinapsis-learning/hooks/observe.sh post",
  "bash ~/.claude/skills/_session-learner.sh",
  "bash ~/.claude/skills/_precompact-guard.sh"
];
console.log(expected.filter(c => cmds.includes(c)).length + " " + cmds.length);
' "$1"
}

# ── Stage 1: _merge-hooks.js unit ──
echo "[Stage 1] _merge-hooks.js unit"

W="$SANDBOX/unit"; mkdir -p "$W"

# T1: missing settings -> created from template, no _comment keys
node "$MERGE" "$TEMPLATE" "$W/s1.json" >/dev/null 2>&1 || true
r=$(count_sinapsis_hooks "$W/s1.json" 2>/dev/null || echo "0 0")
if [ "${r%% *}" = "7" ] && ! grep -q '_comment' "$W/s1.json"; then
  pass "T1: creates settings.json from template (7 hooks, no _comment)"
else
  fail "T1: creates settings.json from template (got: $r)"
fi

# T2: existing settings without hooks -> merged, user keys preserved
printf '{\n  "theme": "dark",\n  "permissions": { "allow": ["mcp__foo"] }\n}\n' > "$W/s2.json"
node "$MERGE" "$TEMPLATE" "$W/s2.json" >/dev/null 2>&1 || true
r=$(count_sinapsis_hooks "$W/s2.json" 2>/dev/null || echo "0 0")
if [ "${r%% *}" = "7" ] && node -e 's=require(process.argv[1]);process.exit(s.theme==="dark"&&s.permissions.allow[0]==="mcp__foo"?0:1)' "$W/s2.json"; then
  pass "T2: merges into hook-less settings.json preserving user keys"
else
  fail "T2: merges into hook-less settings.json preserving user keys (got: $r)"
fi

# T3: existing custom hooks + custom event survive the merge
cat > "$W/s3.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "node /my/custom-tracker.js pre" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "bash /my/notify.sh" } ] }
    ]
  }
}
EOF
node "$MERGE" "$TEMPLATE" "$W/s3.json" >/dev/null 2>&1 || true
r=$(count_sinapsis_hooks "$W/s3.json" 2>/dev/null || echo "0 0")
if [ "${r%% *}" = "7" ] && grep -q "custom-tracker.js" "$W/s3.json" && grep -q "notify.sh" "$W/s3.json"; then
  pass "T3: custom hooks and custom events preserved"
else
  fail "T3: custom hooks and custom events preserved (got: $r)"
fi

# T4: idempotent — second run changes nothing
before=$(cat "$W/s3.json")
node "$MERGE" "$TEMPLATE" "$W/s3.json" >/dev/null 2>&1 || true
after=$(cat "$W/s3.json")
if [ "$before" = "$after" ]; then
  pass "T4: second merge is a no-op (idempotent)"
else
  fail "T4: second merge is a no-op (file changed)"
fi

# T5: partial wiring — an already-present command is not duplicated
cat > "$W/s5.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bash ~/.claude/skills/_instinct-activator.sh", "timeout": 5 } ] }
    ]
  }
}
EOF
node "$MERGE" "$TEMPLATE" "$W/s5.json" >/dev/null 2>&1 || true
n=$(grep -c "_instinct-activator.sh" "$W/s5.json" || true)
r=$(count_sinapsis_hooks "$W/s5.json" 2>/dev/null || echo "0 0")
if [ "$n" = "1" ] && [ "${r%% *}" = "7" ]; then
  pass "T5: pre-existing command not duplicated, missing ones added"
else
  fail "T5: pre-existing command not duplicated (occurrences=$n, wired=${r%% *})"
fi

# T6: BOM'd settings.json is merged and rewritten without BOM
printf '\xef\xbb\xbf{ "theme": "light" }\n' > "$W/s6.json"
node "$MERGE" "$TEMPLATE" "$W/s6.json" >/dev/null 2>&1 || true
first=$(head -c 3 "$W/s6.json" | od -An -tx1 | tr -d ' \n')
r=$(count_sinapsis_hooks "$W/s6.json" 2>/dev/null || echo "0 0")
if [ "${r%% *}" = "7" ] && [ "$first" != "efbbbf" ]; then
  pass "T6: BOM stripped, merge succeeds, no BOM re-emitted"
else
  fail "T6: BOM handling (wired=${r%% *}, first-bytes=$first)"
fi

# T7: malformed settings.json -> non-zero exit, file untouched
printf '{ this is not json' > "$W/s7.json"
if node "$MERGE" "$TEMPLATE" "$W/s7.json" >/dev/null 2>&1; then
  fail "T7: malformed settings.json must exit non-zero"
else
  if [ "$(cat "$W/s7.json")" = "{ this is not json" ]; then
    pass "T7: malformed settings.json left untouched, exit non-zero"
  else
    fail "T7: malformed settings.json was modified"
  fi
fi

# ── Stage 2: install.sh end-to-end ──
echo ""
echo "[Stage 2] install.sh end-to-end (sandboxed HOME)"

# T8: pre-existing settings.json gets ALL hooks wired by the installer
rm -rf "$FAKE_HOME"; mkdir -p "$FAKE_HOME/.claude"
printf '{ "theme": "dark" }\n' > "$FAKE_HOME/.claude/settings.json"
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" >/dev/null 2>&1 || true
r=$(count_sinapsis_hooks "$FAKE_HOME/.claude/settings.json" 2>/dev/null || echo "0 0")
if [ "${r%% *}" = "7" ] && grep -q '"theme": "dark"' "$FAKE_HOME/.claude/settings.json"; then
  pass "T8: installer wires 7 hooks into a pre-existing settings.json"
else
  fail "T8: installer wires hooks into existing settings.json (got: $r)"
fi

# T9: running the installer twice does not duplicate hooks
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" >/dev/null 2>&1 || true
n=$(grep -c "_instinct-activator.sh" "$FAKE_HOME/.claude/settings.json" || true)
if [ "$n" = "1" ]; then
  pass "T9: double install keeps hooks deduplicated"
else
  fail "T9: double install duplicated hooks (occurrences=$n)"
fi

# T10: legacy names are ARCHIVED, not deleted
rm -rf "$FAKE_HOME"; mkdir -p "$FAKE_HOME/.claude/skills/sinapsis-optimizer" "$FAKE_HOME/.claude/commands"
echo "user content that must survive" > "$FAKE_HOME/.claude/skills/sinapsis-optimizer/precious.md"
echo "legacy command" > "$FAKE_HOME/.claude/commands/clone.md"
HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" >/dev/null 2>&1 || true
archived_file=$(find "$FAKE_HOME/.claude/skills/_archived" -name "precious.md" 2>/dev/null | head -1)
archived_cmd=$(find "$FAKE_HOME/.claude/skills/_archived" -name "clone.md" 2>/dev/null | head -1)
if [ ! -d "$FAKE_HOME/.claude/skills/sinapsis-optimizer" ] && [ -n "$archived_file" ] \
   && grep -q "must survive" "$archived_file" && [ -n "$archived_cmd" ]; then
  pass "T10: legacy dirs/commands archived to _archived/legacy-*, content intact"
else
  fail "T10: legacy cleanup must archive, not delete"
fi

# T11: malformed settings.json does not break the install and is not touched
rm -rf "$FAKE_HOME"; mkdir -p "$FAKE_HOME/.claude"
printf '{ broken' > "$FAKE_HOME/.claude/settings.json"
if HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" >/dev/null 2>&1; then
  if [ "$(cat "$FAKE_HOME/.claude/settings.json")" = "{ broken" ]; then
    pass "T11: install completes and malformed settings.json is left untouched"
  else
    fail "T11: malformed settings.json was modified"
  fi
else
  fail "T11: install.sh aborted on malformed settings.json"
fi

# ── Stage 3: static asserts (install.bat, versions, docs) ──
echo ""
echo "[Stage 3] Static asserts"

BAT="$SCRIPT_DIR/install.bat"

# T12: skill copy loop uses xcopy /E (subdirs like hooks/ must be copied)
if grep -E 'xcopy "%%d' "$BAT" | grep -q "/E"; then
  pass "T12: install.bat skill copy uses xcopy /E"
else
  fail "T12: install.bat skill copy misses /E (skill subdirs not installed)"
fi

# T13: no wmic invocation (removed in Windows 11 24H2+) — comments may mention it
if grep -qiE "wmic +[a-z]+ +get|'wmic" "$BAT"; then
  fail "T13: install.bat still invokes wmic"
else
  pass "T13: install.bat does not invoke wmic"
fi

# T14: errorlevel reads inside parenthesised blocks use delayed expansion
if grep -q "enabledelayedexpansion" "$BAT" \
   && awk '/py -3 --version/{found=1} found && /!errorlevel!/{ok=1} END{exit ok?0:1}' "$BAT" \
   && awk '/_merge-hooks.js/{found=1} found && /!errorlevel!/{ok=1} END{exit ok?0:1}' "$BAT"; then
  pass "T14: python detection and settings result use !errorlevel!"
else
  fail "T14: stale %errorlevel% inside parenthesised blocks"
fi

# T15: version consistency — CHANGELOG latest major.minor appears everywhere
LATEST=$(grep -m1 -oE "## v[0-9]+\.[0-9]+" "$SCRIPT_DIR/CHANGELOG.md" | grep -oE "v[0-9]+\.[0-9]+")
ok=1
for f in install.sh install.bat README.md; do
  grep -q "$LATEST" "$SCRIPT_DIR/$f" || { ok=0; echo "       ($f missing $LATEST)"; }
done
if [ "$ok" = "1" ]; then
  pass "T15: CHANGELOG version ($LATEST) present in install.sh, install.bat, README.md"
else
  fail "T15: version drift against CHANGELOG ($LATEST)"
fi

# T16: no stale advertisements — the /clone COMMAND is gone (the legacy cleanup
# path clone.md is allowed: that is the code that archives it), and the
# synapis-* era is gone from quickstart
if ! grep -qE "/clone([^.]|$)" "$SCRIPT_DIR/install.sh" && ! grep -qE "/clone([^.]|$)" "$BAT" \
   && ! grep -qE "synapis-(researcher|optimizer)" "$SCRIPT_DIR/docs/quickstart.md" \
   && ! grep -q "### /clone" "$SCRIPT_DIR/docs/quickstart.md"; then
  pass "T16: /clone and synapis-* era references removed from installers and quickstart"
else
  fail "T16: stale /clone or synapis-* references remain"
fi

# T17: settings.template.json parses and declares exactly the 7 expected commands
tpl_ok=$(node -e '
const fs = require("fs");
const t = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
let n = 0;
for (const groups of Object.values(t.hooks || {}))
  for (const g of groups) n += (g.hooks || []).filter(h => typeof h.command === "string").length;
console.log(n);
' "$TEMPLATE")
if [ "$tpl_ok" = "7" ]; then
  pass "T17: settings.template.json declares 7 hook commands"
else
  fail "T17: settings.template.json declares $tpl_ok hook commands (expected 7)"
fi

# T18: no :: comments inside parenthesised blocks (adversarial review, 2026-07-18):
# cmd.exe delimits ( ) blocks BEFORE recognising ::, so an indented :: comment is
# parsed — and any ')' in its text closes the block and aborts the whole batch at
# parse time with exit 255. All in-file :: comments must sit at column 0, top level.
if grep -qE '^[[:space:]]+::' "$BAT"; then
  fail "T18: indented :: comment inside a block in install.bat (parse-time abort risk)"
else
  pass "T18: no :: comments inside parenthesised blocks in install.bat"
fi

# T19: "hooks": [] (empty array — valid JSON, truthy) must be normalised and wired,
# not silently dropped by JSON.stringify while reporting success
printf '{ "hooks": [] }\n' > "$W/s19.json"
node "$MERGE" "$TEMPLATE" "$W/s19.json" >/dev/null 2>&1 || true
r=$(count_sinapsis_hooks "$W/s19.json" 2>/dev/null || echo "0 0")
if [ "${r%% *}" = "7" ] && node -e 's=require(process.argv[1]);process.exit(!Array.isArray(s.hooks)&&typeof s.hooks==="object"?0:1)' "$W/s19.json"; then
  pass "T19: empty hooks array normalised to object, 7 hooks wired"
else
  fail "T19: empty hooks array ghost-merge (got: $r)"
fi

# T20: "hooks": [non-empty array] cannot be interpreted — exit non-zero, untouched
printf '{ "hooks": [ { "weird": true } ] }\n' > "$W/s20.json"
before=$(cat "$W/s20.json")
if node "$MERGE" "$TEMPLATE" "$W/s20.json" >/dev/null 2>&1; then
  fail "T20: non-empty hooks array must exit non-zero"
else
  if [ "$(cat "$W/s20.json")" = "$before" ]; then
    pass "T20: non-empty hooks array refused, file untouched"
  else
    fail "T20: non-empty hooks array was modified"
  fi
fi

# ── Stage 4: install.bat REAL execution smoke test (Windows hosts only) ──
# Static greps cannot catch cmd.exe parse-time aborts (the exact bug the review
# found). On Windows runners, execute the actual installer in a sandboxed
# USERPROFILE and assert the outcome end-to-end.
echo ""
echo "[Stage 4] install.bat execution smoke test"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    SMOKE_HOME="$SANDBOX/bat_home"; mkdir -p "$SMOKE_HOME"
    WIN_HOME=$(cygpath -w "$SMOKE_HOME")
    WIN_BAT=$(cygpath -w "$SCRIPT_DIR/install.bat")
    code=0
    USERPROFILE="$WIN_HOME" cmd //c "$WIN_BAT" </dev/null >"$SANDBOX/bat_out.log" 2>&1 || code=$?
    obs="$SMOKE_HOME/.claude/skills/sinapsis-learning/hooks/observe.sh"
    r=$(count_sinapsis_hooks "$SMOKE_HOME/.claude/settings.json" 2>/dev/null || echo "0 0")
    cmds=$(ls "$SMOKE_HOME/.claude/commands/"*.md 2>/dev/null | wc -l)
    if [ "$code" = "0" ] && [ -f "$obs" ] && [ "${r%% *}" = "7" ] && [ "$cmds" -gt 0 ]; then
      pass "T21: install.bat executes end-to-end (exit 0, observe.sh on disk, 7 hooks, $cmds commands)"
    else
      fail "T21: install.bat execution (exit=$code, observe.sh=$([ -f "$obs" ] && echo si || echo no), hooks=${r%% *}, cmds=$cmds)"
      tail -15 "$SANDBOX/bat_out.log" 2>/dev/null | sed 's/^/       | /'
    fi
    ;;
  *)
    pass "T21: install.bat execution smoke test (skipped: non-Windows host)"
    ;;
esac

echo ""
echo "=== Results: $PASS/$TESTS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
