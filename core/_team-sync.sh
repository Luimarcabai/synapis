#!/bin/bash
# Sinapsis Teams — deterministic team knowledge sync (v4.7.0)
#
# Shares knowledge each member's Sinapsis learned autonomously through a plain
# per-team git repo. NO hook changes: imported instincts land in the personal
# _instincts-index.json as ordinary draft entries and are validated by the
# existing pipeline (occurrence tracking, auto-promote, decay, /promote,
# /downvote, dream cycle). See docs/TEAMS.md for the design and trust model.
#
# Usage:
#   _team-sync.sh init  <name> <git-url>     create a team (bootstraps empty remote)
#   _team-sync.sh join  <name> <git-url>     join an existing team
#   _team-sync.sh pull  [name]               import new/updated team knowledge
#   _team-sync.sh share <name> <instinct-id> publish one of your validated instincts
#   _team-sync.sh context push|show <name>   share/read per-project agent context
#   _team-sync.sh status                     teams, counts, last sync
#   _team-sync.sh leave <name> [--purge]     remove team (--purge: also its instincts)
#
# Deterministic bash + node, no LLM. Git is the transport; no server, no accounts.

SKILLS="$HOME/.claude/skills"
TEAMS_DIR="$SKILLS/_team"
INDEX="$SKILLS/_instincts-index.json"

CMD="${1:-}"
[ $# -gt 0 ] && shift

die() { echo "ERROR: $1" >&2; exit 1; }

# Team names become directory names — reject traversal and separators outright.
validate_name() {
  case "$1" in
    *..*|*/*|*\\*|.*|"") die "invalid team name '$1' (letters, digits, . _ - only)" ;;
  esac
  echo "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' \
    || die "invalid team name '$1' (letters, digits, . _ - only, max 64)"
}

# Resolve the author once, in bash (git identity → env → OS user).
resolve_author() {
  AUTHOR="${TEAM_AUTHOR:-$(git config user.name 2>/dev/null)}"
  [ -z "$AUTHOR" ] && AUTHOR="${GIT_AUTHOR_NAME:-}"
  [ -z "$AUTHOR" ] && AUTHOR="${USER:-${USERNAME:-unknown}}"
}

# git push with one pull --rebase retry (two members sharing at once).
push_with_retry() {
  git -C "$1" push -q 2>/dev/null && return 0
  git -C "$1" pull --rebase -q 2>/dev/null
  git -C "$1" push -q
}

case "$CMD" in

  # ── init / join ─────────────────────────────────────────────────────────────
  init|join)
    NAME="${1:-}"; URL="${2:-}"
    [ -z "$NAME" ] || [ -z "$URL" ] && die "usage: _team-sync.sh $CMD <name> <git-url>"
    validate_name "$NAME"
    CLONE="$TEAMS_DIR/$NAME"
    [ -d "$CLONE" ] && die "team '$NAME' already exists at $CLONE"
    mkdir -p "$TEAMS_DIR"
    git clone --quiet "$URL" "$CLONE" 2>/dev/null || die "could not clone $URL"

    if [ ! -f "$CLONE/instincts.json" ]; then
      # Empty remote (init) — bootstrap the team repo structure.
      node -e '
        const fs = require("fs"), path = require("path");
        const clone = process.argv[1], team = process.argv[2];
        const now = new Date().toISOString();
        fs.writeFileSync(path.join(clone, "sinapsis-team.json"), JSON.stringify({
          version: "1.0", system: "sinapsis-teams", team: team, created: now,
          policy: {
            import_level: "draft",
            _note: "Level for incoming instincts on /team pull. draft (default) = quarantine, validated by each member own usage. confirmed = trusted team. permanent is NEVER importable."
          }
        }, null, 2) + "\n");
        fs.writeFileSync(path.join(clone, "instincts.json"),
          JSON.stringify({ version: "1.0", instincts: [] }, null, 2) + "\n");
        fs.mkdirSync(path.join(clone, "context"), { recursive: true });
        fs.writeFileSync(path.join(clone, "context", ".gitkeep"), "");
      ' "$CLONE" "$NAME" || die "bootstrap failed"
      git -C "$CLONE" add -A >/dev/null 2>&1
      git -C "$CLONE" commit -qm "chore(team): bootstrap sinapsis team '$NAME'" >/dev/null 2>&1
      git -C "$CLONE" push -q -u origin HEAD >/dev/null 2>&1 \
        || echo "WARN: could not push bootstrap (push manually from $CLONE)"
      echo "Team '$NAME' created. Share your first instinct: /team share $NAME <instinct-id>"
    else
      echo "Joined team '$NAME'. Import its knowledge: /team pull $NAME"
    fi
    ;;

  # ── share ───────────────────────────────────────────────────────────────────
  share)
    NAME="${1:-}"; IID="${2:-}"
    [ -z "$NAME" ] || [ -z "$IID" ] && die "usage: _team-sync.sh share <name> <instinct-id>"
    validate_name "$NAME"
    CLONE="$TEAMS_DIR/$NAME"
    [ -d "$CLONE" ] || die "no team '$NAME' — run /team join first"
    resolve_author
    git -C "$CLONE" pull --rebase -q 2>/dev/null

    node -e '
      const fs = require("fs"), path = require("path");
      const [indexFile, clone, iid, author] = process.argv.slice(1);
      function readJson(p) {
        let raw = fs.readFileSync(p, "utf8");
        if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
        return JSON.parse(raw);
      }
      // Same 8 secret patterns as observe_v3.py — nothing leaves the machine unscrubbed.
      function scrub(v) {
        let s = String(v);
        s = s.replace(/(api[_-]?key|token|secret|password|authorization|credentials?|auth)(["'"'"'\s:=]+)([A-Za-z]+\s+)?([A-Za-z0-9_\-/.+=]{8,})/gi,
          (m, a, b, c) => a + b + (c || "") + "[REDACTED]");
        s = s.replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, "[JWT_REDACTED]");
        s = s.replace(/gh[ps]_[A-Za-z0-9]{36,}/g, "[GITHUB_TOKEN_REDACTED]");
        s = s.replace(/AKIA[A-Z0-9]{16}/g, "[AWS_KEY_REDACTED]");
        s = s.replace(/-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----/g, "[PEM_REDACTED]");
        s = s.replace(/(?:sk_live|sk_test|rk_live|rk_test)_[A-Za-z0-9]{20,}/g, "[STRIPE_KEY_REDACTED]");
        s = s.replace(/xox[bpras]-[A-Za-z0-9\-]{10,}/g, "[SLACK_TOKEN_REDACTED]");
        s = s.replace(/SG\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}/g, "[SENDGRID_KEY_REDACTED]");
        return s;
      }
      let index;
      try { index = readJson(indexFile); } catch (e) { console.error("cannot read instincts index"); process.exit(1); }
      const inst = (index.instincts || []).find(i => i && i.id === iid);
      if (!inst) { console.error("instinct \"" + iid + "\" not found in your index"); process.exit(1); }
      if (inst.level !== "confirmed" && inst.level !== "permanent") {
        console.error("only confirmed/permanent instincts can be shared — \"" + iid + "\" is " + inst.level +
          ". Your own usage has not validated it yet.");
        process.exit(2);
      }
      const teamFile = path.join(clone, "instincts.json");
      let team;
      try { team = readJson(teamFile); } catch (e) { team = { version: "1.0", instincts: [] }; }
      if (!Array.isArray(team.instincts)) team.instincts = [];
      const prev = team.instincts.find(i => i && i.id === iid);
      const entry = {
        id: inst.id,
        domain: inst.domain || "general",
        trigger_pattern: scrub(inst.trigger_pattern || ""),
        inject: scrub(inst.inject || ""),
        author: author,
        shared_at: new Date().toISOString(),
        shared_level: inst.level,
        occurrences_at_share: inst.occurrences || 0,
        revision: (prev && prev.revision ? prev.revision : 0) + 1
      };
      if (prev) Object.assign(prev, entry); else team.instincts.push(entry);
      const tmp = teamFile + ".tmp";
      fs.writeFileSync(tmp, JSON.stringify(team, null, 2) + "\n");
      fs.renameSync(tmp, teamFile);
      console.log("shared \"" + iid + "\" (rev " + entry.revision + ") as " + author);
    ' "$INDEX" "$CLONE" "$IID" "$AUTHOR" || exit $?

    git -C "$CLONE" add -A >/dev/null 2>&1
    git -C "$CLONE" commit -qm "feat(team): share $IID" >/dev/null 2>&1
    push_with_retry "$CLONE" || die "push failed — check remote access"
    ;;

  # ── pull ────────────────────────────────────────────────────────────────────
  pull)
    ONLY="${1:-}"
    [ -d "$TEAMS_DIR" ] || { echo "No teams yet. /team join <name> <git-url> to start."; exit 0; }
    # The dream cycle owns the index while it runs — do not race it.
    [ -f "$SKILLS/_dream.lock" ] && die "dream cycle is running — retry in a minute"

    FOUND=0
    for CLONE in "$TEAMS_DIR"/*/; do
      [ -f "$CLONE/instincts.json" ] || continue
      NAME="$(basename "$CLONE")"
      [ -n "$ONLY" ] && [ "$NAME" != "$ONLY" ] && continue
      FOUND=1
      git -C "$CLONE" pull --rebase -q 2>/dev/null || echo "WARN: pull failed for '$NAME' (offline?) — importing local copy"

      node -e '
        const fs = require("fs"), path = require("path");
        const [clone, teamName, indexFile, ledgerFile] = process.argv.slice(1);
        function readJson(p) {
          let raw = fs.readFileSync(p, "utf8");
          if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
          return JSON.parse(raw);
        }
        function scrub(v) {
          let s = String(v);
          s = s.replace(/(api[_-]?key|token|secret|password|authorization|credentials?|auth)(["'"'"'\s:=]+)([A-Za-z]+\s+)?([A-Za-z0-9_\-/.+=]{8,})/gi,
            (m, a, b, c) => a + b + (c || "") + "[REDACTED]");
          s = s.replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, "[JWT_REDACTED]");
          s = s.replace(/gh[ps]_[A-Za-z0-9]{36,}/g, "[GITHUB_TOKEN_REDACTED]");
          s = s.replace(/AKIA[A-Z0-9]{16}/g, "[AWS_KEY_REDACTED]");
          s = s.replace(/-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----/g, "[PEM_REDACTED]");
          s = s.replace(/(?:sk_live|sk_test|rk_live|rk_test)_[A-Za-z0-9]{20,}/g, "[STRIPE_KEY_REDACTED]");
          s = s.replace(/xox[bpras]-[A-Za-z0-9\-]{10,}/g, "[SLACK_TOKEN_REDACTED]");
          s = s.replace(/SG\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}/g, "[SENDGRID_KEY_REDACTED]");
          return s;
        }
        let shared = [];
        try { shared = readJson(path.join(clone, "instincts.json")).instincts || []; } catch (e) {}
        let policyLevel = "draft";
        try {
          const cfg = readJson(path.join(clone, "sinapsis-team.json"));
          if (cfg.policy && cfg.policy.import_level === "confirmed") policyLevel = "confirmed";
          // anything else (including "permanent") stays draft — permanent is earned, never imported
        } catch (e) {}
        let ledger;
        try { ledger = readJson(ledgerFile); } catch (e) { ledger = { version: "1.0", imported: {} }; }
        if (!ledger.imported) ledger.imported = {};
        let index;
        try { index = readJson(indexFile); } catch (e) { index = { version: "4.1", instincts: [], archived: [] }; }
        if (!Array.isArray(index.instincts)) index.instincts = [];

        const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
        const REDOS = /(\+|\*|\{)\)?(\+|\*|\{)/;   // same nested-quantifier guard as _passive-activator.sh
        const originPrefix = "team:" + teamName + "/";
        let added = 0, updated = 0, skipped = 0;

        for (const s of shared) {
          if (!s || typeof s.id !== "string") { skipped++; continue; }
          const rev = (typeof s.revision === "number" && s.revision > 0) ? s.revision : 1;
          // Hostile-payload gate: id shape, trigger sanity, inject presence.
          if (!ID_RE.test(s.id) || s.id.includes("..")) { skipped++; continue; }
          if (typeof s.trigger_pattern !== "string" || !s.trigger_pattern || REDOS.test(s.trigger_pattern)) { skipped++; continue; }
          try { new RegExp(s.trigger_pattern, "i"); } catch (e) { skipped++; continue; }
          if (typeof s.inject !== "string" || !s.inject.trim()) { skipped++; continue; }
          // Ledger gate: only new ids or bumped revisions. This is also the
          // no-resurrection rule — a locally deleted/downvoted import stays gone.
          if (rev <= (ledger.imported[s.id] || 0)) { skipped++; continue; }
          const existing = index.instincts.find(i => i && i.id === s.id);
          if (existing && !(existing.origin || "").startsWith(originPrefix)) {
            // Collision with the operator own knowledge — personal always wins.
            ledger.imported[s.id] = rev; skipped++; continue;
          }
          const author = (String(s.author || "unknown").replace(/[^A-Za-z0-9 ._-]/g, "").slice(0, 40)) || "unknown";
          const fields = {
            domain: (typeof s.domain === "string" ? s.domain : "general").slice(0, 40),
            trigger_pattern: scrub(s.trigger_pattern).slice(0, 300),
            inject: scrub(s.inject).slice(0, 500),   // scrubbed again on import — defense in depth
            level: policyLevel,                       // draft by default: quarantine, never injected until validated
            origin: originPrefix + author,
            team_rev: rev,
            occurrences: 0                            // validation is local — content revisions start over
          };
          if (existing) { Object.assign(existing, fields); updated++; }
          else {
            index.instincts.push(Object.assign({ id: s.id, added: new Date().toISOString().slice(0, 10) }, fields));
            added++;
          }
          ledger.imported[s.id] = rev;
        }

        if (added || updated) {
          const tmp = indexFile + ".tmp";
          fs.writeFileSync(tmp, JSON.stringify(index, null, 2));
          fs.renameSync(tmp, indexFile);
        }
        const ltmp = ledgerFile + ".tmp";
        fs.writeFileSync(ltmp, JSON.stringify(ledger, null, 2));
        fs.renameSync(ltmp, ledgerFile);
        console.log("[" + teamName + "] " + added + " imported, " + updated + " updated, " + skipped + " skipped" +
          (added || updated ? " — new imports are drafts: they activate after YOUR usage validates them (or /promote)" : ""));
      ' "$CLONE" "$NAME" "$INDEX" "$TEAMS_DIR/$NAME.imported.json" || echo "WARN: import failed for '$NAME'"
    done
    [ "$FOUND" = "0" ] && echo "No matching team clones under $TEAMS_DIR."
    ;;

  # ── context ─────────────────────────────────────────────────────────────────
  context)
    SUB="${1:-}"; NAME="${2:-}"
    [ -z "$SUB" ] && die "usage: _team-sync.sh context push|show <name>"

    # Key the context by the project's git remote — the cross-machine-stable id
    # (same derivation as observe_v3.py: sha256(remote || root)[:12]).
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
    [ -z "$ROOT" ] && die "not inside a git project"
    REMOTE_URL="$(git -C "$ROOT" remote get-url origin 2>/dev/null)"
    KEY="${REMOTE_URL:-$ROOT}"
    PROJECT_ID="$(node -e 'console.log(require("crypto").createHash("sha256").update(process.argv[1]).digest("hex").slice(0,12))' "$KEY")"
    SLUG="$(echo "$KEY" | sed -e 's|^[a-z+]*://||' -e 's|[^A-Za-z0-9._-]|-|g' | cut -c1-80)"

    case "$SUB" in
      push)
        [ -z "$NAME" ] && die "usage: _team-sync.sh context push <name>"
        validate_name "$NAME"
        CLONE="$TEAMS_DIR/$NAME"
        [ -d "$CLONE" ] || die "no team '$NAME' — run /team join first"
        SRC="$HOME/.claude/homunculus/projects/$PROJECT_ID/context.md"
        [ -f "$SRC" ] || die "no context.md for this project yet (Sinapsis writes it as you work)"
        git -C "$CLONE" pull --rebase -q 2>/dev/null
        mkdir -p "$CLONE/context"
        node -e '
          const fs = require("fs");
          const [src, dst, slug] = process.argv.slice(1);
          function scrub(v) {
            let s = String(v);
            s = s.replace(/(api[_-]?key|token|secret|password|authorization|credentials?|auth)(["'"'"'\s:=]+)([A-Za-z]+\s+)?([A-Za-z0-9_\-/.+=]{8,})/gi,
              (m, a, b, c) => a + b + (c || "") + "[REDACTED]");
            s = s.replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, "[JWT_REDACTED]");
            s = s.replace(/gh[ps]_[A-Za-z0-9]{36,}/g, "[GITHUB_TOKEN_REDACTED]");
            s = s.replace(/AKIA[A-Z0-9]{16}/g, "[AWS_KEY_REDACTED]");
            s = s.replace(/-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----/g, "[PEM_REDACTED]");
            s = s.replace(/(?:sk_live|sk_test|rk_live|rk_test)_[A-Za-z0-9]{20,}/g, "[STRIPE_KEY_REDACTED]");
            s = s.replace(/xox[bpras]-[A-Za-z0-9\-]{10,}/g, "[SLACK_TOKEN_REDACTED]");
            s = s.replace(/SG\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}/g, "[SENDGRID_KEY_REDACTED]");
            return s;
          }
          fs.writeFileSync(dst, scrub(fs.readFileSync(src, "utf8")));
          console.log("context published as context/" + slug + ".md");
        ' "$SRC" "$CLONE/context/$SLUG.md" "$SLUG" || die "context scrub failed"
        git -C "$CLONE" add -A >/dev/null 2>&1
        git -C "$CLONE" commit -qm "docs(team): project context $SLUG" >/dev/null 2>&1
        push_with_retry "$CLONE" || die "push failed — check remote access"
        ;;
      show)
        SHOWN=0
        for CLONE in "$TEAMS_DIR"/*/; do
          [ -d "$CLONE" ] || continue
          [ -n "$NAME" ] && [ "$(basename "$CLONE")" != "$NAME" ] && continue
          F="$CLONE/context/$SLUG.md"
          if [ -f "$F" ]; then
            echo "── team $(basename "$CLONE") · context/$SLUG.md ──"
            cat "$F"
            SHOWN=1
          fi
        done
        [ "$SHOWN" = "0" ] && echo "No team context for this project. A teammate can publish it: /team context push <name>"
        ;;
      *) die "usage: _team-sync.sh context push|show <name>" ;;
    esac
    ;;

  # ── status ──────────────────────────────────────────────────────────────────
  status)
    [ -d "$TEAMS_DIR" ] || { echo "No teams. /team init <name> <git-url> to create one."; exit 0; }
    FOUND=0
    for CLONE in "$TEAMS_DIR"/*/; do
      [ -f "$CLONE/instincts.json" ] || continue
      FOUND=1
      NAME="$(basename "$CLONE")"
      LAST="$(git -C "$CLONE" log -1 --format=%cI 2>/dev/null || echo '?')"
      node -e '
        const fs = require("fs"), path = require("path");
        const [clone, name, ledgerFile, last] = process.argv.slice(1);
        function readJson(p) {
          let raw = fs.readFileSync(p, "utf8");
          if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
          return JSON.parse(raw);
        }
        let shared = []; try { shared = readJson(path.join(clone, "instincts.json")).instincts || []; } catch (e) {}
        let led = {};   try { led = readJson(ledgerFile).imported || {}; } catch (e) {}
        const pending = shared.filter(s => s && s.id && (s.revision || 1) > (led[s.id] || 0)).length;
        console.log("  " + name + ": " + shared.length + " shared, " +
          Object.keys(led).length + " imported, " + pending + " pending (/team pull), last commit " + last);
      ' "$CLONE" "$NAME" "$TEAMS_DIR/$NAME.imported.json" "$LAST"
    done
    [ "$FOUND" = "0" ] && echo "No teams. /team init <name> <git-url> to create one."
    ;;

  # ── leave ───────────────────────────────────────────────────────────────────
  leave)
    NAME="${1:-}"; PURGE="${2:-}"
    [ -z "$NAME" ] && die "usage: _team-sync.sh leave <name> [--purge]"
    validate_name "$NAME"
    CLONE="$TEAMS_DIR/$NAME"
    [ -d "$CLONE" ] || die "no team '$NAME'"
    rm -rf "$CLONE"
    rm -f "$TEAMS_DIR/$NAME.imported.json"
    echo "Left team '$NAME' (clone + import ledger removed)."
    if [ "$PURGE" = "--purge" ]; then
      [ -f "$SKILLS/_dream.lock" ] && die "dream cycle is running — retry the purge in a minute"
      node -e '
        const fs = require("fs");
        const [indexFile, prefix] = process.argv.slice(1);
        let raw = fs.readFileSync(indexFile, "utf8");
        if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
        const index = JSON.parse(raw);
        const before = (index.instincts || []).length;
        index.instincts = (index.instincts || []).filter(i => !(i && (i.origin || "").startsWith(prefix)));
        const tmp = indexFile + ".tmp";
        fs.writeFileSync(tmp, JSON.stringify(index, null, 2));
        fs.renameSync(tmp, indexFile);
        console.log("Purged " + (before - index.instincts.length) + " instincts from team " + prefix.slice(5, -1) + ".");
      ' "$INDEX" "team:$NAME/" 2>/dev/null || echo "WARN: purge skipped (no readable index)"
    fi
    ;;

  *)
    cat <<'USAGE'
Sinapsis Teams — share what your team has learned (docs/TEAMS.md)

  _team-sync.sh init  <name> <git-url>      create a team
  _team-sync.sh join  <name> <git-url>      join an existing team
  _team-sync.sh pull  [name]                import new/updated team knowledge
  _team-sync.sh share <name> <instinct-id>  publish a confirmed/permanent instinct
  _team-sync.sh context push|show <name>    share/read per-project agent context
  _team-sync.sh status                      teams, counts, last sync
  _team-sync.sh leave <name> [--purge]      remove team (--purge: also its instincts)
USAGE
    exit 1
    ;;
esac
