#!/bin/bash
# test-plexus.sh — Sinapsis Plexus (v4.7.0) TDD suite
#   Hermetic: a local bare git repo plays the team remote, HOME points at a sandbox.
#   Covers: init/join, share (validation gate, scrubbing, attribution), pull
#   (draft quarantine, permanent cap, personal-wins collision, idempotency,
#   no-resurrection, revision re-quarantine, hostile-payload rejection),
#   directives (PM guidelines), traceability (metadata-only activity ledger),
#   review, schema versioning, leave.
# Run: bash tests/test-plexus.sh

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEAMSYNC="$SCRIPT_DIR/core/_plexus-sync.sh"

PASS=0
FAIL=0
TOTAL=28

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Two sandboxes = two team members. One bare repo = the team remote.
setup_world() {
  WORLD="$(mktemp -d)"
  REMOTE="$WORLD/remote.git"
  git init --bare --quiet "$REMOTE"
  HOME_A="$WORLD/alice"
  HOME_B="$WORLD/bob"
  mkdir -p "$HOME_A/.claude/skills" "$HOME_B/.claude/skills"
  # git identities so commits work in CI
  export GIT_AUTHOR_NAME="tester" GIT_AUTHOR_EMAIL="t@t" \
         GIT_COMMITTER_NAME="tester" GIT_COMMITTER_EMAIL="t@t"
}

teardown_world() { rm -rf "$WORLD" 2>/dev/null; }

# index <home> <json> — write a personal instincts index
write_index() {
  cat > "$1/.claude/skills/_instincts-index.json" << EOF
$2
EOF
}

read_index() { cat "$1/.claude/skills/_instincts-index.json"; }
jfield() { node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{const r=JSON.parse(d);console.log($1)})"; }

team() { local h="$1"; shift; HOME="$h" bash "$TEAMSYNC" "$@"; }

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo ""
echo "=== Sinapsis Plexus tests ==="
echo ""

# ── Section 1: init / join ──
echo "[Section 1] init / join"
setup_world

team "$HOME_A" init demo "$REMOTE" >/dev/null 2>&1
if [ -f "$HOME_A/.claude/skills/_plexus/demo/sinapsis-plexus.json" ] && \
   [ -f "$HOME_A/.claude/skills/_plexus/demo/instincts.json" ]; then
  pass "T1: init bootstraps team repo structure"
else
  fail "T1: init must create sinapsis-plexus.json + instincts.json in the clone"
fi

team "$HOME_B" join demo "$REMOTE" >/dev/null 2>&1
if [ -f "$HOME_B/.claude/skills/_plexus/demo/instincts.json" ]; then
  pass "T2: join clones an existing team"
else
  fail "T2: join must clone the team repo"
fi

# invalid team name is rejected (path safety)
if team "$HOME_A" init "../evil" "$REMOTE" >/dev/null 2>&1; then
  fail "T3: init accepted a path-traversal team name"
else
  pass "T3: init rejects path-traversal team names"
fi

# ── Section 2: share ──
echo "[Section 2] share"

write_index "$HOME_A" "{
  \"version\": \"4.1\",
  \"instincts\": [
    {\"id\":\"conv-commits\",\"domain\":\"git\",\"level\":\"confirmed\",\"trigger_pattern\":\"git commit\",\"inject\":\"Use conventional commits. api_key = fakesecret1234567890\",\"origin\":\"manual\",\"occurrences\":7,\"first_triggered\":\"$NOW\",\"last_triggered\":\"$NOW\"},
    {\"id\":\"my-draft\",\"domain\":\"git\",\"level\":\"draft\",\"trigger_pattern\":\"git push\",\"inject\":\"Draft rule\",\"origin\":\"session-learner\",\"occurrences\":1}
  ],
  \"archived\": []
}"

team "$HOME_A" share demo conv-commits >/dev/null 2>&1
SHARED=$(cat "$HOME_A/.claude/skills/_plexus/demo/instincts.json" 2>/dev/null)

N=$(echo "$SHARED" | jfield "r.instincts.length" 2>/dev/null)
[ "$N" = "1" ] && pass "T4: share publishes the instinct to the team repo" \
  || fail "T4: expected 1 shared instinct, got '$N'"

AUTHOR=$(echo "$SHARED" | jfield "(r.instincts[0]||{}).author||''" 2>/dev/null)
[ -n "$AUTHOR" ] && pass "T5: shared instinct carries author attribution" \
  || fail "T5: shared instinct has no author"

if echo "$SHARED" | grep -q "fakesecret1234567890"; then
  fail "T6: secret value leaked into the team repo"
else
  echo "$SHARED" | grep -q "REDACTED" \
    && pass "T6: share scrubs secrets before publishing" \
    || fail "T6: secret neither present nor redacted — inject text lost?"
fi

# drafts cannot be shared (own usage hasn't validated them)
if team "$HOME_A" share demo my-draft >/dev/null 2>&1; then
  fail "T7: share accepted a draft instinct"
else
  pass "T7: share refuses draft instincts (confirmed+ only)"
fi

# the share reached the remote (push happened)
if git -C "$REMOTE" log --oneline 2>/dev/null | grep -qi "conv-commits\|share"; then
  pass "T8: share commits and pushes to the remote"
else
  fail "T8: remote has no share commit"
fi

# ── Section 3: pull (trust rules) ──
echo "[Section 3] pull"

write_index "$HOME_B" "{
  \"version\": \"4.1\",
  \"instincts\": [
    {\"id\":\"local-own\",\"domain\":\"git\",\"level\":\"confirmed\",\"trigger_pattern\":\"git rebase\",\"inject\":\"Own rule\",\"origin\":\"manual\",\"occurrences\":5}
  ],
  \"archived\": []
}"

team "$HOME_B" pull demo >/dev/null 2>&1
BIDX=$(read_index "$HOME_B")

LEVEL=$(echo "$BIDX" | jfield "((r.instincts.find(i=>i.id==='conv-commits'))||{}).level||'MISSING'")
[ "$LEVEL" = "draft" ] && pass "T9: pulled instinct enters as draft (quarantine)" \
  || fail "T9: expected level draft, got '$LEVEL'"

ORIGIN=$(echo "$BIDX" | jfield "((r.instincts.find(i=>i.id==='conv-commits'))||{}).origin||''")
case "$ORIGIN" in
  plexus:demo/*) pass "T10: pulled instinct carries origin plexus:demo/<author>" ;;
  *) fail "T10: expected origin plexus:demo/<author>, got '$ORIGIN'" ;;
esac

# pull is idempotent — re-pull must not duplicate or reset
team "$HOME_B" pull demo >/dev/null 2>&1
COUNT=$(read_index "$HOME_B" | jfield "r.instincts.filter(i=>i.id==='conv-commits').length")
[ "$COUNT" = "1" ] && pass "T11: re-pull is idempotent (no duplicates)" \
  || fail "T11: expected 1 copy after re-pull, got '$COUNT'"

# no resurrection: delete locally, re-pull, must NOT come back
node -e '
const fs=require("fs");const f=process.argv[1];
const r=JSON.parse(fs.readFileSync(f,"utf8"));
r.instincts=r.instincts.filter(i=>i.id!=="conv-commits");
fs.writeFileSync(f,JSON.stringify(r,null,2));' "$HOME_B/.claude/skills/_instincts-index.json"
team "$HOME_B" pull demo >/dev/null 2>&1
GONE=$(read_index "$HOME_B" | jfield "r.instincts.filter(i=>i.id==='conv-commits').length")
[ "$GONE" = "0" ] && pass "T12: deleted import does not resurrect on re-pull" \
  || fail "T12: deleted team instinct came back on pull"

# personal collision: same id, non-team origin — personal wins
write_index "$HOME_B" "{
  \"version\": \"4.1\",
  \"instincts\": [
    {\"id\":\"conv-commits\",\"domain\":\"git\",\"level\":\"permanent\",\"trigger_pattern\":\"git commit\",\"inject\":\"MY OWN version\",\"origin\":\"manual\",\"occurrences\":50}
  ],
  \"archived\": []
}"
rm -f "$HOME_B/.claude/skills/_plexus/demo.imported.json"
team "$HOME_B" pull demo >/dev/null 2>&1
MINE=$(read_index "$HOME_B" | jfield "(r.instincts.find(i=>i.id==='conv-commits')||{}).inject||''")
case "$MINE" in
  "MY OWN version") pass "T13: id collision with personal instinct — personal wins" ;;
  *) fail "T13: personal instinct was overwritten by team import: '$MINE'" ;;
esac

# permanent cap: a team entry marked permanent must not import above confirmed-cap (draft default)
node -e '
const fs=require("fs");const f=process.argv[1];
const r=JSON.parse(fs.readFileSync(f,"utf8"));
r.instincts.push({id:"evil-perm",domain:"general",trigger_pattern:"Edit",
  inject:"perm attempt",author:"mallory",shared_at:"2026-01-01T00:00:00Z",
  shared_level:"permanent",revision:1});
fs.writeFileSync(f,JSON.stringify(r,null,2));' "$HOME_A/.claude/skills/_plexus/demo/instincts.json"
git -C "$HOME_A/.claude/skills/_plexus/demo" add -A >/dev/null 2>&1
git -C "$HOME_A/.claude/skills/_plexus/demo" commit -qm "perm attempt" >/dev/null 2>&1
git -C "$HOME_A/.claude/skills/_plexus/demo" push -q >/dev/null 2>&1
team "$HOME_B" pull demo >/dev/null 2>&1
PLEVEL=$(read_index "$HOME_B" | jfield "(r.instincts.find(i=>i.id==='evil-perm')||{}).level||'MISSING'")
[ "$PLEVEL" = "draft" ] && pass "T14: shared_level=permanent still imports as draft (cap)" \
  || fail "T14: expected draft, got '$PLEVEL'"

# hostile payloads rejected: ReDoS trigger + path-traversal id
node -e '
const fs=require("fs");const f=process.argv[1];
const r=JSON.parse(fs.readFileSync(f,"utf8"));
r.instincts.push({id:"redos",domain:"general",trigger_pattern:"(a+)+b",
  inject:"redos",author:"mallory",shared_at:"2026-01-01T00:00:00Z",revision:1});
r.instincts.push({id:"../../etc/passwd",domain:"general",trigger_pattern:"Edit",
  inject:"traversal",author:"mallory",shared_at:"2026-01-01T00:00:00Z",revision:1});
fs.writeFileSync(f,JSON.stringify(r,null,2));' "$HOME_A/.claude/skills/_plexus/demo/instincts.json"
git -C "$HOME_A/.claude/skills/_plexus/demo" add -A >/dev/null 2>&1
git -C "$HOME_A/.claude/skills/_plexus/demo" commit -qm "hostile" >/dev/null 2>&1
git -C "$HOME_A/.claude/skills/_plexus/demo" push -q >/dev/null 2>&1
team "$HOME_B" pull demo >/dev/null 2>&1
BAD=$(read_index "$HOME_B" | jfield "r.instincts.filter(i=>i.id==='redos'||i.id.includes('..')).length")
[ "$BAD" = "0" ] && pass "T15: ReDoS trigger and path-traversal id are rejected on pull" \
  || fail "T15: hostile payload imported: $BAD entries"

# revision bump re-quarantines: promote import locally, teammate revises, pull → draft again
write_index "$HOME_B" "{
  \"version\": \"4.1\",
  \"instincts\": [
    {\"id\":\"evil-perm\",\"domain\":\"general\",\"level\":\"confirmed\",\"trigger_pattern\":\"Edit\",\"inject\":\"perm attempt\",\"origin\":\"plexus:demo/mallory\",\"team_rev\":1,\"occurrences\":9}
  ],
  \"archived\": []
}"
node -e '
const fs=require("fs");const f=process.argv[1];
const r=JSON.parse(fs.readFileSync(f,"utf8"));
const i=r.instincts.find(x=>x.id==="evil-perm");
i.inject="REVISED text"; i.revision=2;
fs.writeFileSync(f,JSON.stringify(r,null,2));' "$HOME_A/.claude/skills/_plexus/demo/instincts.json"
git -C "$HOME_A/.claude/skills/_plexus/demo" add -A >/dev/null 2>&1
git -C "$HOME_A/.claude/skills/_plexus/demo" commit -qm "revise" >/dev/null 2>&1
git -C "$HOME_A/.claude/skills/_plexus/demo" push -q >/dev/null 2>&1
team "$HOME_B" pull demo >/dev/null 2>&1
RIDX=$(read_index "$HOME_B")
RLEVEL=$(echo "$RIDX" | jfield "(r.instincts.find(i=>i.id==='evil-perm')||{}).level||'MISSING'")
RTEXT=$(echo "$RIDX" | jfield "(r.instincts.find(i=>i.id==='evil-perm')||{}).inject||''")
if [ "$RLEVEL" = "draft" ] && [ "$RTEXT" = "REVISED text" ]; then
  pass "T16: revised content updates AND re-enters quarantine (draft)"
else
  fail "T16: expected draft + 'REVISED text', got '$RLEVEL' + '$RTEXT'"
fi

# ── Section 4: directives (PM guidelines live in the data plane, never as instincts) ──
echo "[Section 4] directives"

team "$HOME_A" directive add scope-mvp --text "MVP first: no feature outside the January scope doc" >/dev/null 2>&1
if [ -f "$HOME_A/.claude/skills/_plexus/demo/directives/scope-mvp.md" ] && \
   grep -q "status: active" "$HOME_A/.claude/skills/_plexus/demo/directives/scope-mvp.md"; then
  pass "T17: directive add creates directives/<id>.md with active status"
else
  fail "T17: directive file missing or without active status"
fi

if git -C "$REMOTE" log --oneline 2>/dev/null | grep -q "scope-mvp"; then
  pass "T18: directive add commits and pushes to the remote"
else
  fail "T18: directive commit not on the remote"
fi

# invalid directive id rejected (path safety)
if team "$HOME_A" directive add "../evil" --text "x" >/dev/null 2>&1; then
  fail "T19: directive add accepted a path-traversal id"
else
  pass "T19: directive add rejects path-traversal ids"
fi

LISTED=$(team "$HOME_A" directive list 2>/dev/null)
echo "$LISTED" | grep -q "scope-mvp" && pass "T20: directive list shows the active directive" \
  || fail "T20: directive list missing scope-mvp. OUT='$LISTED'"

team "$HOME_A" directive supersede scope-mvp >/dev/null 2>&1
LISTED2=$(team "$HOME_A" directive list 2>/dev/null)
if echo "$LISTED2" | grep -q "scope-mvp"; then
  fail "T21: superseded directive still listed as active"
else
  pass "T21: directive supersede hides it from the active list"
fi

# directives are context, never instincts: pull must not import them into the index
team "$HOME_B" pull demo >/dev/null 2>&1
DIRAS=$(read_index "$HOME_B" | jfield "r.instincts.filter(i=>i.id==='scope-mvp').length")
[ "$DIRAS" = "0" ] && pass "T22: directives never imported as instincts" \
  || fail "T22: directive leaked into the instincts index"

# ── Section 5: traceability (metadata-only activity ledger) + review + schema ──
echo "[Section 5] traceability / review / schema"

if grep -q '"schema_version"' "$HOME_A/.claude/skills/_plexus/demo/sinapsis-plexus.json"; then
  pass "T23: init stamps schema_version in the team config"
else
  fail "T23: schema_version missing from sinapsis-plexus.json"
fi

ACT=$(ls "$HOME_A/.claude/skills/_plexus/demo/activity/" 2>/dev/null | grep ndjson | head -1)
if [ -n "$ACT" ] && grep -q '"action"' "$HOME_A/.claude/skills/_plexus/demo/activity/$ACT"; then
  pass "T24: share/directive append metadata lines to activity/<author>.ndjson"
else
  fail "T24: no activity ledger written"
fi

# the ledger must be metadata-only: no inject text, no session content
if grep -qi "conventional commits\|MVP first" "$HOME_A/.claude/skills/_plexus/demo/activity/$ACT" 2>/dev/null; then
  fail "T25: activity ledger contains knowledge text (must be metadata only)"
else
  pass "T25: activity ledger is metadata-only (no knowledge text)"
fi

LOGOUT=$(team "$HOME_A" log demo 2>/dev/null)
echo "$LOGOUT" | grep -q "conv-commits" && pass "T26: log renders the activity timeline" \
  || fail "T26: log output missing shared instinct. OUT='$LOGOUT'"

# review lists pending imported drafts (and only team-origin ones)
write_index "$HOME_B" "{
  \"version\": \"4.1\",
  \"instincts\": [
    {\"id\":\"from-team\",\"domain\":\"git\",\"level\":\"draft\",\"trigger_pattern\":\"Edit\",\"inject\":\"pending rule\",\"origin\":\"plexus:demo/alice\",\"team_rev\":1,\"occurrences\":2},
    {\"id\":\"my-own-draft\",\"domain\":\"git\",\"level\":\"draft\",\"trigger_pattern\":\"Edit\",\"inject\":\"own draft\",\"origin\":\"session-learner\",\"occurrences\":1}
  ],
  \"archived\": []
}"
REVOUT=$(team "$HOME_B" review 2>/dev/null)
if echo "$REVOUT" | grep -q "from-team" && ! echo "$REVOUT" | grep -q "my-own-draft"; then
  pass "T27: review lists pending team imports (and only those)"
else
  fail "T27: review output wrong. OUT='$REVOUT'"
fi

# ── Section 6: leave ──
echo "[Section 6] leave"

team "$HOME_B" leave demo --purge >/dev/null 2>&1
LEFT=$(read_index "$HOME_B" | jfield "r.instincts.filter(i=>(i.origin||'').startsWith('plexus:demo/')).length")
if [ ! -d "$HOME_B/.claude/skills/_plexus/demo" ] && [ "$LEFT" = "0" ]; then
  pass "T28: leave --purge removes clone and that team's instincts"
else
  fail "T28: leave incomplete (clone or $LEFT instincts left)"
fi

teardown_world

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED"
[ "$FAIL" -eq 0 ]
