# Sinapsis Teams

> Share what your team has *learned* — not what someone curated.
> An opt-in layer that lets a development team pool the instincts and project
> context each member's Sinapsis learned autonomously, through a plain git repo.

Status: v1 shipped in v4.7.0. OFF by default — solo installs are unaffected.

---

## The decision: same repo, optional module (not a fork)

Two options were on the table: a separate `sinapsis-teams` repository, or an
optional module inside `Luispitik/sinapsis`. **Same repo wins**, for four reasons:

1. **The team layer is a data-exchange protocol, not a second product.** It
   reuses ~90% of the existing machinery: the index schema, quarantine
   (draft level), occurrence tracking, auto-promote, confidence decay,
   `/downvote`, `/promote`, and the dream cycle all apply to imported team
   instincts *unmodified*. A separate repo would either fork that machinery or
   depend on its internals — both fragile against Sinapsis's release cadence
   (six releases between v4.3 and v4.6.2).
2. **Zero runtime changes.** v1 touches no hook. Imported instincts land in the
   operator's `_instincts-index.json` as ordinary entries; the activator,
   learner and dream cycle don't know teams exist. Code that isn't executed
   for solo users can't regress them.
3. **Philosophy holds.** Sinapsis is *autonomous learning* (v4.3.2 separation).
   The seeds proposal (PR #8) was rejected because it distributed *curated
   foreign content by default*. Teams is the opposite on both axes: the content
   is knowledge a teammate's Sinapsis **learned from real sessions**, and
   nothing happens unless the operator explicitly runs `/team join`. Opt-in
   sharing of learned knowledge *is* the product; pre-cooked libraries are not.
4. **What actually needs separation is data, and it gets it.** Each team's
   knowledge lives in its own private git repo, owned by the team — the
   Sinapsis codebase never contains anyone's knowledge.

## Architecture

```
                    team knowledge repo (private git repo, per team)
                    ├── sinapsis-team.json      config + import policy
                    ├── instincts.json          shared instincts + provenance
                    └── context/<slug>.md       per-project agent context
                              ▲          │
                    /team share│          │/team pull
                              │          ▼
   member A ── Sinapsis ── _instincts-index.json        member B ── Sinapsis ── ...
   (learns autonomously)   (team imports enter          (validates imports through
                            as draft, origin team:)      its OWN usage before injecting)
```

- **Local clone**: `~/.claude/skills/_team/<name>/` (one per team; multi-team supported).
- **Import ledger**: `~/.claude/skills/_team/<name>.imported.json` — records
  `{id: revision}` for everything ever imported. Pull only imports new ids or
  bumped revisions, which makes pull idempotent and prevents *resurrection*:
  an instinct you deleted or downvoted does not come back on the next pull.
- **Provenance**: imported entries carry `origin: "team:<name>/<author>"` and
  `team_rev`. `/instinct-status`, the dashboard and the dream cycle can always
  tell learned-by-me from shared-by-team. `/team leave --purge` removes them
  cleanly by origin prefix.

## Trust model

A team repo is a trust boundary you opt into — a private repo shared with
colleagues, like their git hooks or their dotfiles. Inside that boundary the
layer still defends the operator's index:

| Invariant | Enforcement |
|---|---|
| Nothing shared reaches your prompts unvalidated | Imports enter at `draft` (never injected). They activate only after the existing pipeline validates them **against your own usage** (auto-promote at 5 real matches) or you promote them explicitly. |
| `permanent` is earned locally, never imported | Import level is capped at `confirmed` even if the team policy asks for more. |
| Your knowledge wins collisions | An incoming id that already exists with a non-team origin is skipped. |
| No secrets leave the machine | `share` scrubs with the same 8 secret patterns as `observe_v3.py` (API keys, JWT, GitHub/AWS/Stripe/Slack/SendGrid tokens, PEM blocks). Pull scrubs again — defense in depth against careless teammates. |
| No hostile payloads | Import validates ids (kebab-case, length-capped, path-traversal safe), rejects ReDoS-prone triggers (nested-quantifier check, same as the passive activator), and caps `inject` length. |
| Content changes re-quarantine | If a teammate revises an instinct you had validated, the revision re-enters as `draft`. Validation is of *content*, not of *id*. |

## Commands (`/team` → `core/_team-sync.sh`)

| Command | What it does |
|---|---|
| `/team init <name> <git-url>` | Create a team: clone (or bootstrap an empty remote), write `sinapsis-team.json` + empty `instincts.json`. |
| `/team join <name> <git-url>` | Join an existing team (clone). |
| `/team pull [name]` | `git pull` each team clone, import new/updated instincts under the trust rules above, sync shared project context. |
| `/team share <name> <instinct-id>` | Publish one of *your* instincts. Must be `confirmed` or `permanent` — you cannot share what your own usage hasn't validated. Scrubbed, attributed, committed, pushed. |
| `/team context push <name>` | Publish the current project's `context.md` (scrubbed) keyed by the project's git remote — the cross-machine-stable key. |
| `/team context show [name]` | Print the team's shared context for the current project. |
| `/team status` | Teams, counts, pending imports, last sync. |
| `/team leave <name> [--purge]` | Remove clone + ledger; `--purge` also removes that team's instincts from your index. |

Everything is deterministic bash + node — no LLM in the loop, same as the rest
of the pipeline. Git is the transport and the conflict story (pull --rebase,
one retry on push race). No server, no accounts, no telemetry.

## Why instincts enter the personal index (and not a parallel one)

A parallel `_team-instincts-index.json` was considered and rejected: it would
need its own activator read path, its own decay, its own dedup against the
personal index, its own dream-cycle rules — duplicated logic that drifts. By
importing into the personal index with provenance fields, every existing
mechanism works on team knowledge for free, and the operator's tools
(`/instinct-status`, `/downvote`, `/promote`, `/dream`) see one world.

The cost — team entries "pollute" the personal index — is contained by the
origin prefix (filterable everywhere) and the ledger (clean removal, no
resurrection).

## The agentic-management angle

The shared `context/` directory is project knowledge keyed by git remote:
architecture decisions, gotchas, active constraints — the things an agent
needs on session one in a repo it has never seen. A teammate runs
`/team context push`; when you `/team pull`, that context is on disk for your
agent before your first prompt in that project. v1 keeps this command-driven;
hook-time injection (merging team context into `_project-context.sh`'s
once-per-session inject) is the natural v2 once the data model has soaked.

## v2 candidates (explicitly out of v1)

- Hook-time team-context injection (`_project-context.sh` merge).
- Shared decision log (`decisions/decisions.jsonl`, append-only).
- Downvote propagation (team-level confidence from member signals).
- `/team review` — batch-review pending imports instead of per-instinct `/promote`.
