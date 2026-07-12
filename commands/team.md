# /team -- Sinapsis Teams

> Share what your team has *learned* — not what someone curated.
> Pools the instincts and project context each member's Sinapsis learned
> autonomously, through a plain private git repo. Opt-in, OFF by default.
> Design + trust model: docs/TEAMS.md

---

## Trigger

Run with `/team <subcommand>` or "sinapsis teams".

---

## Subcommands

All of them delegate to the deterministic script — run it directly, do not
reimplement the logic:

```
bash ~/.claude/skills/_team-sync.sh <subcommand> [args]
```

| Subcommand | Effect |
|---|---|
| `/team init <name> <git-url>` | Create a team (bootstraps an empty private remote) |
| `/team join <name> <git-url>` | Join an existing team |
| `/team pull [name]` | Import new/updated team knowledge |
| `/team share <name> <instinct-id>` | Publish one of YOUR validated instincts |
| `/team context push <name>` | Publish the current project's context (scrubbed) |
| `/team context show [name]` | Print the team's context for the current project |
| `/team status` | Teams, counts, pending imports, last sync |
| `/team leave <name> [--purge]` | Remove team; `--purge` also removes its instincts |

---

## Rules (enforced by the script — explain them to the user when relevant)

- **Share gate**: only `confirmed`/`permanent` instincts can be shared. If the
  user asks to share a `draft`, explain that their own usage hasn't validated
  it yet and suggest `/promote` after real occurrences.
- **Import quarantine**: pulled instincts enter as `draft` with
  `origin: team:<name>/<author>`. They are NOT injected until the user's own
  usage validates them (auto-promote at 5 matches) or the user runs `/promote`.
- **`permanent` is never importable** — it is earned locally.
- **Personal wins**: an incoming id that collides with a non-team instinct is
  skipped silently. Never overwrite the operator's own knowledge.
- **Secrets**: share and pull both scrub with the same 8 patterns as
  `observe_v3.py`. Still, warn the user before sharing instincts whose inject
  text looks project-confidential.

---

## Example session

```
/team init acme git@github.com:acme/sinapsis-knowledge.git
  Team 'acme' created. Share your first instinct: /team share acme <instinct-id>

/team share acme supabase-rls-check
  shared "supabase-rls-check" (rev 1) as Luis

/team pull
  [acme] 3 imported, 0 updated, 1 skipped — new imports are drafts: they
  activate after YOUR usage validates them (or /promote)

/team status
  acme: 12 shared, 9 imported, 3 pending (/team pull), last commit 2026-07-13
```

---

## After a pull

Suggest `/instinct-status` so the user sees the imported drafts, and remind
them: nothing shared reaches their prompts until validated. To review imports
in bulk, `/promote` lists eligible instincts once they accumulate occurrences.
