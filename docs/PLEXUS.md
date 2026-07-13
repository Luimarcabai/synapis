# Sinapsis Plexus

> **Wire your team's synapses into one nervous system** — peer-to-peer over
> git, no server, trust earned by your own use.
>
> A *plexus* is the anatomical level right above the synapse: a network of
> nerves from multiple origins that interweave and redistribute signal with no
> center. That is exactly this layer: every member's Sinapsis keeps learning
> autonomously; Plexus is the network where the validated knowledge circulates
> between peers.

Status: v1 shipped in v4.7.0. Opt-in, OFF by default — solo installs are unaffected.

---

## The problem it solves

Development teams bleed knowledge. The gotcha one dev hit on Tuesday is
rediscovered by another on Friday. Project decisions live in someone's head,
the PM's framing drifts away from what the team actually learned, and when a
repo changes hands the context goes with the person who left. Every member's
Sinapsis already captures that knowledge *individually* — Plexus makes it
circulate, without losing the one property that makes Sinapsis trustworthy:
**nothing reaches your prompts that your own usage hasn't validated.**

## The decision: same repo, optional module (not a fork)

Two options were on the table: a separate repository, or an optional module
inside `Luispitik/sinapsis`. **Same repo wins**, for four reasons:

1. **Plexus is a data-exchange protocol, not a second product.** It reuses
   ~90% of the existing machinery: the index schema, quarantine (draft level),
   occurrence tracking, auto-promote, confidence decay, `/downvote`,
   `/promote`, and the dream cycle all apply to imported knowledge *unmodified*.
2. **Zero runtime changes.** v1 touches no hook. Imported instincts land in
   the operator's `_instincts-index.json` as ordinary entries; the activator,
   learner and dream cycle don't know Plexus exists. Code that isn't executed
   for solo users can't regress them.
3. **Philosophy holds.** Sinapsis is *autonomous learning* (v4.3.2 separation).
   The seeds proposal (PR #8) was rejected because it distributed *curated
   foreign content by default*. Plexus is the opposite on both axes: the
   content is knowledge a teammate's Sinapsis **learned from real sessions**,
   and nothing happens unless the operator explicitly runs `/plexus join`.
4. **What actually needs separation is data, and it gets it.** Each team's
   knowledge lives in its own private git repo, owned by the team — the
   Sinapsis codebase never contains anyone's knowledge.

The complement to this decision: everything that requires *semantic* reasoning
over the team repo (contradiction detection between members, between a member
and a directive, or between the team's reality and the PM's framing) lives
**outside** this repo, in a separate consumer product — an LLM call inside the
Sinapsis runtime would break the founding "zero LLM" invariant. Plexus's job
is to make the data plane complete enough that such a consumer needs to touch
zero files here.

## Architecture

```
                team knowledge repo (private git repo, per team)
                ├── sinapsis-plexus.json     config · schema_version · import policy
                ├── instincts.json           shared instincts + author/revision provenance
                ├── directives/<id>.md       PM guidelines (frontmatter: scope, status, version)
                ├── context/<slug>.md        per-project agent context (keyed by git remote)
                └── activity/<member>.ndjson metadata-only contribution ledger
                          ▲          │
              /plexus share│          │/plexus pull
               directive add│          │review · log
                          │          ▼
   member A ── Sinapsis ── _instincts-index.json     member B ── Sinapsis ── ...
   (learns autonomously)  (imports enter as draft,   (validates imports through
                           origin plexus:)            their OWN usage)
```

- **Local clone**: `~/.claude/skills/_plexus/<name>/` (one per team; multi-team supported).
- **Import ledger**: `~/.claude/skills/_plexus/<name>.imported.json` — records
  `{id: revision}` for everything ever imported. Pull only imports new ids or
  bumped revisions, which makes pull idempotent and prevents *resurrection*:
  an instinct you deleted or downvoted does not come back on the next pull.
- **Provenance**: imported entries carry `origin: "plexus:<name>/<author>"` and
  `team_rev`. `/instinct-status`, the dashboard and the dream cycle can always
  tell learned-by-me from shared-by-team. `/plexus leave --purge` removes them
  cleanly by origin prefix.
- **Schema contract**: `sinapsis-plexus.json` carries `schema_version` with an
  **additive-only policy** — consumers must tolerate unknown fields, and
  existing fields are never repurposed. This is what lets external products
  (dashboards, audit engines) build on the team repo without coupling to
  Sinapsis's release cadence.

## Trust model

A team repo is a trust boundary you opt into — a private repo shared with
colleagues, like their git hooks or their dotfiles. Inside that boundary the
layer still defends the operator's index. The biological metaphor is
*myelination*: a neural pathway strengthens only through repeated use — shared
knowledge arrives dormant and only consolidates when **your own usage**
validates it.

| Invariant | Enforcement |
|---|---|
| Nothing shared reaches your prompts unvalidated | Imports enter at `draft` (never injected). They activate only after the existing pipeline validates them **against your own usage** (auto-promote at 5 real matches) or you promote them explicitly. `/plexus review` shows the quarantine queue. |
| `permanent` is earned locally, never imported | Import level is capped at `confirmed` even if the team policy asks for more. |
| Your knowledge wins collisions | An incoming id that already exists with a non-plexus origin is skipped. |
| No secrets leave the machine | `share`, `directive add` and `context push` scrub with the same 8 secret patterns as `observe_v3.py` (API keys, JWT, GitHub/AWS/Stripe/Slack/SendGrid tokens, PEM blocks). Pull scrubs again — defense in depth against careless teammates. |
| No hostile payloads | Import validates ids (kebab-case, length-capped, path-traversal safe), rejects ReDoS-prone triggers (nested-quantifier check, same as the passive activator), and caps `inject` length. |
| Content changes re-quarantine | If a teammate revises an instinct you had validated, the revision re-enters as `draft`. Validation is of *content*, not of *id*. |
| Traceability, not surveillance | `activity/` records **metadata of knowledge contributions only** (author, action, id, revision) — never session text, never what anyone *read*. The line between knowledge traceability and employee monitoring is a hard design boundary. |
| Directives are context, never instincts | PM guidelines live in `directives/` and are read as guidance. There is deliberately **no code path** that imports a directive into the instincts index — top-down curated content injected as instincts is the rejected seeds model (PR #8). |

## Commands (`/plexus` → `core/_plexus-sync.sh`)

| Command | What it does |
|---|---|
| `/plexus init <name> <git-url>` | Create a team: clone (or bootstrap an empty remote), write config + structure. |
| `/plexus join <name> <git-url>` | Join an existing team (clone). |
| `/plexus pull [name]` | `git pull` each team clone, import new/updated instincts under the trust rules, sync directives and shared context. |
| `/plexus share <name> <instinct-id>` | Publish one of *your* instincts. Must be `confirmed`/`permanent` — you cannot share what your own usage hasn't validated. Scrubbed, attributed, committed, pushed. |
| `/plexus review` | The quarantine queue: pending team imports, who shared them, and how close each is to auto-promote. |
| `/plexus directive add <id> --text "..." [--scope <slug>]` | PM sets a guideline. Versioned file in `directives/`, git history is the audit trail. |
| `/plexus directive list [--all]` | Active guidelines (`--all` includes superseded). |
| `/plexus directive supersede <id>` | Retire a guideline without deleting its history. |
| `/plexus log [name] [--member <a>]` | Traceability timeline from the metadata ledger. |
| `/plexus context push <name>` | Publish the current project's `context.md` (scrubbed) keyed by the project's git remote — the cross-machine-stable key. |
| `/plexus context show [name]` | Print the team's shared context for the current project. |
| `/plexus status` | Teams, counts, pending imports, last sync. |
| `/plexus leave <name> [--purge]` | Remove clone + ledger; `--purge` also removes that team's instincts from your index. |

Everything is deterministic bash + node — no LLM in the loop, same as the rest
of the pipeline. Git is the transport and the conflict story (pull --rebase,
one retry on push race). No server, no accounts, no telemetry.

## Why instincts enter the personal index (and not a parallel one)

A parallel index was considered and rejected: it would need its own activator
read path, its own decay, its own dedup against the personal index, its own
dream-cycle rules — duplicated logic that drifts. By importing into the
personal index with provenance fields, every existing mechanism works on team
knowledge for free, and the operator's tools (`/instinct-status`, `/downvote`,
`/promote`, `/dream`) see one world.

The cost — team entries "pollute" the personal index — is contained by the
origin prefix (filterable everywhere) and the ledger (clean removal, no
resurrection).

## The project-management angle

Three of the four functions a PM needs are deterministic and live here:

- **Directives** — the PM's framing of the project (goals, constraints,
  scope) as versioned files the whole team and their agents can read.
- **Individual knowledge collection** — the share/pull loop itself.
- **Traceability** — who contributed what knowledge, when (metadata ledger +
  git history).

The fourth — **contradiction detection** (member vs member, member vs
directive, and *the team's reality vs the PM's framing*) — is semantic and
requires an LLM. It belongs to an external consumer product that reads this
repo as its API (see the schema contract above). By design, that consumer
needs zero changes in Sinapsis.

## v2 candidates (explicitly out of v1)

- Hook-time team-context + directives injection (`_project-context.sh` merge).
- Downvote propagation (team-level confidence from member signals).
- Batch promote from `/plexus review`.
- Shared decision log (append-only).
