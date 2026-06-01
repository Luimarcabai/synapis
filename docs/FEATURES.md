# Sinapsis v4.5 — Feature Reference

> Complete inventory of all features, commands, hooks, modules, and capabilities.
> **Update this file with every feat/fix commit.**
> Last updated: 2026-04-21

---

## Architecture Overview

Sinapsis is a continuous learning system for Claude Code that observes sessions, detects patterns, and crystallizes them into reusable knowledge — automatically.

### Knowledge Pipeline

```
OBSERVATIONS  →  PROPOSALS  →  INSTINCTS (JSON)
(JSONL, async)   (pending)     draft → confirmed → permanent
  observe_v3.py   session-      /analyze-session    /promote
                  learner.sh    /evolve
                                      ↓
                               SKILLS / COMMANDS / PASSIVE RULES
                                         (evolved)
```

Parallel systems (not part of the confidence pipeline):
- **Passive Rules** (6 default) — deterministic regex rules, always fire on matcher
- **Operator State** — strategic decisions persisted across all projects
- **Skill Router** — on-demand skill loading from dormant catalog

### Dual Injection Architecture

| Injection Point | What | When | Tokens |
|---|---|---|---|
| **SessionStart** | Project context.md + EOD resume | Once per session (via _project-context.sh) | ~150 |
| **PreToolUse** | Instincts (max 3) + Passive Rules (max 3) | Every tool use (if trigger matches) | ~200 max |

### 7-Hook Pipeline (v4.5)

| Hook | File | Lines | Event | Mode | Timeout |
|---|---|---|---|---|---|
| Observer | `observe_v3.py` | 200 | Pre/PostToolUse | Async (0 tokens) | 10s |
| Project Context | `_project-context.sh` | 136 | PreToolUse | Sync (1x/session) | 3s |
| Passive Activator | `_passive-activator.sh` | 66 | PreToolUse | Sync | 5s |
| Instinct Activator | `_instinct-activator.sh` | 226 | PreToolUse | Sync | 5s |
| Observer (post) | `observe_v3.py` | — | PostToolUse | Async | 10s |
| Session Learner | `_session-learner.sh` | 329 | Stop | Sync | 15s |
| PreCompact Guard | `_precompact-guard.sh` | 30 | PreCompact | Sync (fire-and-forget) | 10s |

**v4.5 additions:** PreCompact hook flushes the learner before context compaction so long sessions do not lose fresh observations. Instinct injection is now byte-stable across calls (id-alphabetical tiebreaker) to unlock prompt-cache hits on Opus 4.7+'s cached system block. Caps raised: `TOKEN_BUDGET` 1500→4000, top-N instincts 3→6, observation window 1000→5000 lines.

**v4.6 additions (Opus 4.8):** caps re-tuned for 4.8's stronger long-context handling — `TOKEN_BUDGET` 4000→6000, top-N instincts 6→8, observation window 5000→8000 lines. 4.8's 1,024-token cache minimum and mid-conversation `system` messages make the byte-stable instinct injection cache more readily. The hot path stays model-free.

---

## Hooks (8 files)

### observe_v3.py — Observation Capture (200 lines)
- Single Python process, captures ALL tool uses as JSONL
- **8 secret scrubbing patterns**: API keys, JWT, PEM, GitHub tokens, AWS keys, Stripe keys, Slack tokens, SendGrid keys
- **9 error detection patterns** with word boundaries (avoids false positives like "0 errors found")
- **is_error flag** + **err_msg** extraction (max 500 chars) on each observation
- **file_path capture** for Edit/Write tools (used by correction detector)
- Session ID and project detection via git remote hash
- Auto-archive at 10MB with file locking (fcntl on Unix, fallback on Windows)
- Restrictive permissions (chmod 600) on data files
- Subagent filtering (agent_id present → skip)
- Entrypoint filtering (cli/sdk/api/claude-desktop only)

### _instinct-activator.sh — Real-time Instinct Injection (221 lines)
- Reads `_instincts-index.json`, matches trigger patterns against tool context
- **Domain pre-filter**: detects project stack from context.md (React, Supabase, Stripe, Prisma, Python, etc.), skips irrelevant domains
- **Domain dedup**: max 1 instinct per domain, max 3 total. Priority: permanent > confirmed, tiebreak by occurrences
- **Occurrence tracking**: increments count + timestamps on every match (including drafts)
- **Multi-session auto-promote**: draft → confirmed requires 5+ occurrences AND 3+ distinct sessions (tracks `sessions_seen[]`)
- **Confidence decay**: confirmed (60d inactive) → draft, draft (90d inactive) → archived. Permanent never decays
- **Token budget cap**: max 1500 chars injected per tool use
- **Path traversal protection**: blocks inject content containing `../`, `~/`, `/etc/`, `/proc/`
- **Prompt injection sanitization**: 500 char cap + 10 blocked keyword patterns
- **ReDoS protection**: rejects patterns with nested quantifiers
- **Race condition safety**: skips write if dream lock held
- **Atomic writes**: tmp + rename pattern
- Uses `execFileSync` (not `execSync`) for command injection prevention

### _passive-activator.sh — Passive Rules Engine (66 lines)
- Matches passive rules (regex) against tool name + input
- Max 3 rules per tool use
- ReDoS protection on trigger patterns
- Separate from instincts — deterministic guardrails, no confidence

### _project-context.sh — Session Bridge (136 lines)
- Fires ONCE per session (flag in tmpdir)
- Injects two sources: EOD daily summary + project context.md
- Validates operator-state schema
- Cleans stale flag files

### _session-learner.sh — Pattern Detection at Session End (329 lines)
- **5 pattern detectors**:
  1. **Error-fix pairs**: is_error flag → same tool success within 5 events
  2. **User corrections**: same file edited 2+ times within 10-event window
  3. **Workflow chains**: 3-tool trigrams repeated 2+ times
  4. **Repetitions**: same error pattern across 3+ distinct sessions (cross-session memory via proposals history)
  5. **Agent patterns**: subagent error capture from Agent tool calls
- Writes `context.md` per project (name, date, files touched, error count)
- Enriched proposals with project_name, sample_input, sample_output, err_msg
- Session-based proposals (overwrite on new day, not accumulative)
- Reads last 1000 lines of observations (covers parallel sessions)
- Pure deterministic Node.js, NO LLM

### _dream.sh — Dream Cycle / Index Hygiene (501 lines)
- **5 modules**:
  1. **Duplicate detection**: Jaccard word-token similarity, threshold 0.80
  2. **Contradiction detection**: 7 opposing keyword pairs (EN + ES), same-domain only
  3. **Staleness scoring**: fresh/stale/archive_candidate/never_activated. Auto-archive: draft + 0 occurrences + >90 days
  4. **Trigger validation**: regex validity, overly broad patterns, ReDoS check
  5. **Health score**: 0-100 composite with penalties and bonuses
- Generates `_dream-report.md` with executive summary
- Lock file (`_dream.lock`) with 1-hour stale detection
- Atomic writes throughout

### _eod-gather.sh — Multi-Project EOD (161 lines)
- Scans ALL `homunculus/projects/` for today's observations
- Extracts tools used, files touched, error count per project
- Cross-references `_projects.json` for names/roots
- Runs git log/status/branch per project root

---

## Commands (15)

| Command | Purpose |
|---|---|
| `/analyze-session` | Deep session analysis: reviews observations + proposals, detects semantic patterns, proposes instincts |
| `/backup [path]` | Export full Sinapsis state to portable folder (any cloud: OneDrive, Google Drive, Dropbox, iCloud) |
| `/cleanup` | Remove legacy files, orphan projects, old archives from homunculus |
| `/downvote [id]` | Demote or archive instincts that give bad advice (feedback loop) |
| `/dream` | Dream Cycle: 5-module index hygiene with dedup, contradictions, staleness, trigger validation, health |
| `/eod` | End-of-day multi-project summary. Saves context for session continuity |
| `/evolve` | Cluster mature instincts → skills, commands, passive rules, agents |
| `/instinct-status` | Dashboard: all instincts with levels, domains, occurrences, cross-project search |
| `/passive-status` | Dashboard: passive rules with activation counts |
| `/projects` | List registered projects with stats |
| `/promote [id]` | Promote instinct: confirmed → permanent |
| `/restore [path]` | Import Sinapsis state from backup with intelligent merge (by ID, keeps local data) |
| `/session-end` | Document session: what was done, pending, decisions. Updates memory |
| `/skill-audit` | Token overhead, duplicates, conflicts, cleanup proposals |
| `/system-status` | Full system dashboard: skills, tokens, operator state, sync |

---

## Confidence Lifecycle

| Level | Injection | Auto-promote | Decay |
|---|---|---|---|
| **draft** | Not injected (tracked only) | → confirmed at 5+ occ AND 3+ sessions | → archived at 90d inactive |
| **confirmed** | Injected when trigger matches | — | → draft at 60d inactive |
| **permanent** | Injected, highest priority | — | Never decays |

---

## Passive Rules (6 default)

Deterministic regex rules — not probabilistic. Always fire when trigger matches.

| Rule | Trigger | Action |
|---|---|---|
| `env-never-commit` | git add/commit | Check .env in .gitignore |
| `html-twin-deliverables` | Write .docx/.pptx/.pdf | Generate HTML twin |
| `git-commit-quality` | git commit | Conventional commits, tests first |
| `decision-capture` | Architecture/strategy keywords | Document the decision |
| `security-headers-check` | Edit vercel.json/next.config | Verify security headers |
| `api-auth-reminder` | Edit route.ts/api/ | Validate authentication |

---

## Security Features

- **8-pattern secret scrubbing** on all observations (API keys, JWT, PEM, GitHub, AWS, Stripe, Slack, SendGrid)
- **Prompt injection sanitization** (10 blocked keywords + 500 char cap + control char stripping)
- **Path traversal protection** (`../`, `~/`, `/etc/`, `/proc/` blocked in inject content)
- **Command injection prevention** (`execFileSync` instead of `execSync`)
- **ReDoS protection** (nested quantifier ban on all regex compilation)
- **Token budget cap** (1500 chars/tool-use, prevents instinct loops)
- **Atomic file writes** everywhere (tmp + rename pattern)
- **File locking** (fcntl on Unix, fallback on Windows)
- **Race condition safety** (dream lock check before index write)
- **Restrictive permissions** (chmod 600 on data files)
- **Subagent filtering** (agent_id observations skipped)
- **Debug mode** behind `SINAPSIS_DEBUG=1` flag (no silent error swallowing)

---

## Portability

- **`/backup [path]`**: exports instincts, rules, operator-state, commands, settings, CLAUDE.md + manifest
- **`/restore [path]`**: merge by ID (keeps local occurrence data, asks before overwriting machine-specific files)
- **`/cleanup`**: removes v1 legacy files, orphan projects (30+ days), old archives (60+ days)
- **Cloud-agnostic**: works with OneDrive, Google Drive, Dropbox, iCloud, rclone, USB, any folder
- **No network needed** between machines — cloud service handles sync

---

## Installer (install.sh + install.bat)

### Cross-Platform
- **Bash** (macOS/Linux): `bash install.sh`
- **Batch** (Windows): `install.bat`

### Smart Upgrade
- Version detection via `_catalog.json`
- Preserves ALL user data: instincts, passive rules, projects, operator state, CLAUDE.md
- Backup before upgrade (timestamped)
- `--force-update` flag for explicit overwrite
- **Legacy file cleanup**: removes obsolete files from v3.2/v4.4 on upgrade

### What Gets Updated
- 6 hook scripts (core/_*.sh)
- All skills (sinapsis-learning, sinapsis-instincts, skill-router)
- All commands (15 .md files)
- Config templates (_catalog.json, settings.template.json)
- Hook wiring in settings.json (if not exists)

---

## Skills (3)

| Skill | Type | Purpose | Tokens |
|---|---|---|---|
| `skill-router` | Global (always active) | Session entry, launcher, skill catalog, on-demand loading | ~4,150 |
| `sinapsis-learning` | Global (always active) | Learning pipeline docs, observe hooks | ~1,250 |
| `sinapsis-instincts` | Global (always active) | Instinct format, confidence levels, domain dedup rules | ~1,515 |

**Total session overhead**: ~6,915 tokens

---

## Tests (6 suites, 83 tests)

| Suite | Tests | Coverage |
|---|---|---|
| `test-dream.sh` | 25 | Dream cycle: all 5 modules (dedup, contradictions, staleness, triggers, report) |
| `test-e2e-dream.sh` | 15 | Dream cycle E2E: full pipeline with fabricated sandbox data |
| `test-gstack-separation.sh` | 18 | Core integrity after gstack removal, no dangling references |
| `test-install-upgrade.sh` | ~14 | Install/upgrade safety: data preservation, backup, --force-update |
| `test-security.sh` | 11 | Command injection, ReDoS, secret scrubbing (JWT, GitHub, AWS) |
| `test-v433-hardening.sh` | 14 | Downvote, scrubbing patterns, path traversal, token cap, multi-session promote |

### CI
- GitHub Actions: ubuntu-latest + macos-latest + windows-latest
- Node 18, Python 3.12
- `fail-fast: false` for full matrix coverage
- Pre-push hook (`.githooks/pre-push`) blocks push if tests fail

---

## Data Directory Structure

```
~/.claude/
├── CLAUDE.md                         # Entry point (loaded every session)
├── settings.json                     # Hook configuration (6 hooks)
├── skills/
│   ├── skill-router/SKILL.md         # Orchestrator (always active)
│   ├── sinapsis-learning/            # Learning engine (always active)
│   │   ├── SKILL.md
│   │   └── hooks/
│   │       ├── observe.sh            # Bash wrapper
│   │       └── observe_v3.py         # Python observer
│   ├── sinapsis-instincts/SKILL.md   # Instincts knowledge base
│   ├── _instincts-index.json         # All instincts (single JSON)
│   ├── _passive-rules.json           # Passive rules
│   ├── _instinct-proposals.json      # Pending proposals from session-learner
│   ├── _instinct-activator.sh        # PreToolUse hook
│   ├── _passive-activator.sh         # PreToolUse hook
│   ├── _session-learner.sh           # Stop hook
│   ├── _project-context.sh           # PreToolUse hook (1x/session)
│   ├── _dream.sh                     # Dream cycle (manual/scheduled)
│   ├── _eod-gather.sh                # EOD helper
│   ├── _operator-state.json          # Identity + decisions (cross-project)
│   ├── _projects.json                # Project registry
│   ├── _catalog.json                 # Skill registry with token estimates
│   ├── _instinct.log                 # Activation audit trail
│   ├── _passive.log                  # Passive rule audit trail
│   ├── _daily-summaries/             # EOD summaries (*.md)
│   ├── _library/                     # Dormant skills (installed on demand)
│   └── _archived/                    # Retired skills (recoverable)
├── commands/                          # 15 slash commands (*.md)
└── homunculus/
    ├── .last-learn                    # Marker for session-learner
    └── projects/
        └── {sha256hash}/
            ├── observations.jsonl     # Raw tool observations (local only)
            ├── context.md             # Last session summary
            └── observations.archive/  # Rotated observations (>10MB)
```

---

## Token Budget

| Component | Tokens | When |
|---|---|---|
| 3 global skills (router + learning + instincts) | ~6,915 | Every session |
| Passive rules (matched only) | ~20–80 | Per matching tool use |
| Instincts (matched only, max 3) | ~50–200 | Per matching tool use |
| Project context bridge | ~50–150 | Once per session |
| **Total session start** | **~6,915–7,200** | |
| **Injection budget cap** | **1,500 chars** | Per tool use |

---

## Version History

| Version | Date | Highlights |
|---|---|---|
| v3.2 | 2026-03 | Initial public release. Skills on Demand architecture |
| v4.1 | 2026-03-31 | Closed learning pipeline. 3-level confidence. Domain dedup |
| v4.1.1 | 2026-04-01 | Critical fixes: auto-resume, analyze-session rename, install.bat parity |
| v4.2.0 | 2026-04-05 | 3 pattern detectors, occurrence tracking, auto-promote (5+) |
| v4.2.2 | 2026-04-06 | Multi-project EOD, E2E tests, projectName scope fix |
| v4.3.0 | 2026-04-08 | Dream Cycle (5 modules), 40 new tests |
| v4.3.1 | 2026-04-08 | Fersora audit: 22 bugs + 6 vulns fixed. Directory cleanup (-41% tokens) |
| v4.3.2 | 2026-04-12 | GStack separation: focused on learning only. Repo renamed to Luispitik/sinapsis |
| v4.3.3 | 2026-04-13 | Cortex comparison hardening: /downvote, 8 scrubbing patterns, path traversal, token cap, multi-session promote, 5 detectors, CI/CD, /backup, /restore, /cleanup |
