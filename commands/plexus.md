# /plexus -- Sinapsis Plexus

> Wire your team's synapses into one nervous system.
> A plexus is the anatomical level above the synapse: a network of nerves from
> multiple origins interweaving and redistributing signal — with no center.
> That is this layer: every member's Sinapsis keeps learning on its own; Plexus
> shares the validated knowledge peer-to-peer over a private git repo.
> Opt-in, OFF by default. Design + trust model: docs/PLEXUS.md

---

## Trigger

Run with `/plexus <subcommand>` or "sinapsis plexus".

---

## Subcommands

All of them delegate to the deterministic script — run it directly, do not
reimplement the logic:

```
bash ~/.claude/skills/_plexus-sync.sh <subcommand> [args]
```

| Subcommand | Effect |
|---|---|
| `/plexus init <name> <git-url>` | Create a team (bootstraps an empty private remote) |
| `/plexus join <name> <git-url>` | Join an existing team |
| `/plexus pull [name]` | Import new/updated team knowledge |
| `/plexus share <name> <instinct-id>` | Publish one of YOUR validated instincts |
| `/plexus review` | List pending team imports awaiting your validation |
| `/plexus directive add <id> --text "..." [--scope <slug>]` | PM sets a project guideline |
| `/plexus directive list [--all]` | Show active directives (`--all` includes superseded) |
| `/plexus directive supersede <id>` | Retire a directive (history stays in git) |
| `/plexus log [name] [--member <a>]` | Traceability: who contributed what, when |
| `/plexus context push <name>` | Publish the current project's context (scrubbed) |
| `/plexus context show [name]` | Print the team's context for the current project |
| `/plexus status` | Teams, counts, pending imports, last sync |
| `/plexus leave <name> [--purge]` | Remove team; `--purge` also removes its instincts |

When the operator belongs to exactly one team, `directive` and `log` may omit
the team name.

---

## Rules (enforced by the script — explain them to the user when relevant)

- **Share gate**: only `confirmed`/`permanent` instincts can be shared. If the
  user asks to share a `draft`, explain that their own usage hasn't validated
  it yet and suggest `/promote` after real occurrences.
- **Import quarantine**: pulled instincts enter as `draft` with
  `origin: plexus:<name>/<author>`. They are NOT injected until the user's own
  usage validates them (auto-promote at 5 matches) or the user runs `/promote`.
  `/plexus review` shows the quarantine queue.
- **`permanent` is never importable** — it is earned locally.
- **Personal wins**: an incoming id that collides with a non-team instinct is
  skipped silently. Never overwrite the operator's own knowledge.
- **Directives are context, never instincts**: they live in `directives/` in
  the team repo and are read as project guidance. They are never imported into
  the instincts index — importing curated top-down content as instincts is the
  rejected seeds model (PR #8).
- **Traceability is metadata-only**: `activity/` records what knowledge moved
  (id + revision + author + action), never session text and never consumption.
  Knowledge traceability, not surveillance.
- **Secrets**: share, pull, directives and context push all scrub with the same
  8 patterns as `observe_v3.py`. Still, warn the user before sharing content
  that looks project-confidential.

---

## Example session

```
/plexus init acme git@github.com:acme/plexus-knowledge.git
  Team 'acme' created. Share your first instinct: /plexus share acme <instinct-id>

/plexus share acme supabase-rls-check
  shared "supabase-rls-check" (rev 1) as Luis

/plexus directive add scope-mvp --text "MVP first: no feature outside the January scope doc"
  directive "scope-mvp" v1 (scope: global) set by Luis

/plexus pull
  [acme] 3 imported, 0 updated, 1 skipped — new imports are drafts: they
  activate after YOUR usage validates them (or /promote)

/plexus review
  PENDING TEAM IMPORTS (draft — not injected until validated)
    stripe-webhook-verify  [saas]  from acme/Ana  · 2/5 matches toward auto-promote

/plexus log
  [acme] activity (latest 3 of 3):
    2026-07-13T10:12:44Z  Luis  share  supabase-rls-check (rev 1)
    2026-07-13T10:13:02Z  Luis  directive_add  scope-mvp (rev 1)
```

---

## After a pull

Suggest `/plexus review` so the user sees the quarantine queue, and remind
them: nothing shared reaches their prompts until validated. `/plexus directive
list` shows the PM guidelines in force for the team.
