# Ghiath - Agent Guidelines

These are the rules for any AI agent working inside this repository (the Ghiath
personal agentic ecosystem).
They adapt Isfa's global agent guidelines to this specific project.
The agents and directories here are different from the `/opt/data/.a2a/` setup
used by Isfa's other agents, so follow this file, not that one, when working in
this repo.

---

## 1. General Guidelines

- **Never use the em dash "-"**: Use plain dash "-" instead.
- **Commit Messages**: When writing commit messages, NEVER auto-add your agent name as co-author.
- **Auto-generated Files**: Never manually modify `CHANGELOG.md` files or any files that are marked as auto-generated.
- **Markdown Writing**: When writing or substantially editing long Markdown files, put each full sentence on its own line.
Preserve normal Markdown structure, but avoid wrapping multiple sentences onto one physical line.
- **Technical Decisions**: When making technical decisions, do not give much weight to development cost.
Instead, prefer quality, simplicity, robustness, scalability, and long term maintainability.
- **Bug Fixes**: When doing bug fixes, always start with reproducing the bug in an E2E setting as closely aligned with how an end user would experience it.
This makes sure you find the real problem so your fix will actually solve it.
- **Engineering Excellence**: Apply a high standard to engineering excellence: lint, test failures, and test flakiness.
If you see one, even if it is not caused by what you are working on right now, still get it fixed.
- **No emoji**: Do not use emoji anywhere in this repo - files, commits, or output.

---

## 2. Scope: this is a light-usage project

Ghiath is deliberately small.
It is two assistants, a notes vault, and the minimum glue needed to reach them from Telegram.
There is no loop engineering here: no planner, no task graph, no retry or escalation
logic, no orchestration across agents.
The heavy, production-shaped version lives in a separate repo, `ghiath-loop`.

When you are asked to add something here, the default answer is the smaller one.
Prefer deleting a moving part over adding one.
Machinery that only pays off at scale does not belong in this repo.

---

## 3. The Agents

There are exactly two agents, one per side of life, and they are fully isolated
from each other.
Each is a separate hermes profile with its own home directory, config, keys,
memory, and gateway.

| Agent | Audience | Owns |
| --- | --- | --- |
| work (`WORK_NAME`) | Isfa alone. Technical work. | `vault-work/` |
| home (`HOME_NAME`) | Isfa and his wife. Everyday life. | `vault-home/` |

There is no router, no lead agent, and no handoffs between them.
Each agent does its whole job itself.
An earlier version of this project ran a team of three role agents behind an n8n
router; that is gone, and nothing should reintroduce it.

Names, models, ports, vault folders, and collections are configuration, not code:
they live in `agents.conf` (gitignored; `agents.conf.example` is the template).
Never hardcode an agent name, model slug, or vault path in a script.

Each profile's role is written into its `SOUL.md` by `scripts/hermes.sh`, inside
a block delimited by `<!-- ghiath:role:begin -->` and `<!-- ghiath:role:end -->`.
That block is regenerated on every run.
To change what an agent believes about itself, edit the heredoc in `hermes.sh`
and re-run it; do not hand-edit `SOUL.md`, because the next run overwrites it.

---

## 4. The isolation boundary

The two sides must never meet. This is a hard requirement, not a preference:
the household agent is shared with another person, and the work vault is not.

Four things enforce it, and all four must stay true:

1. Separate hermes profiles, so neither can read the other's config or memory.
2. Separate vault directories, and each agent's `SOUL.md` names only its own
   absolute path.
3. Separate Qdrant collections, so semantic search cannot cross.
   The home indexer only mounts the home vault; it physically cannot see the
   work one.
4. Separate CouchDB databases and separate Telegram bots, so a household device
   or chat has no path to work notes.

Before changing anything in `docker-compose.yml`, `sync-env.sh`, or `hermes.sh`,
check that you have not created a fifth path between the two sides.

---

## 5. The confirmation gate

The work agent must not execute a technical task without explicit confirmation
from Isfa over Telegram.
The rule is written into its `SOUL.md` by `scripts/hermes.sh` and is controlled
by `WORK_CONFIRM_GATE` in `agents.conf`.

The protocol is: plan out loud, ask, wait, then execute exactly the plan that was
confirmed.
Reads, searches, explanations, and planning are not gated.
One confirmation covers one plan and never becomes standing permission.

If you are editing that text, keep it unambiguous and keep the literal
confirmation line intact.
A gate that the agent can talk itself out of is not a gate.

---

## 6. Persistence: never cost the user state

Deploying an update must never invalidate a Telegram session, drop a hermes
session, or touch a note.
Three invariants protect that, and changes to the setup scripts must preserve
all three:

- **`scripts/hermes.sh` is non-destructive by default.**
  It creates a profile only when missing and otherwise reconfigures in place.
  It must never call `hermes profile delete` outside the opt-in, interactive
  `--reset` path, because deleting a profile wipes `sessions/`, `memories/`, and
  the per-profile `.env` that holds the Telegram bot token.
- **Vault seeding is additive.**
  The `seed` helper skips any file that already exists. Never make it overwrite.
- **Every vault is gitignored** via the `vault*/` pattern.
  A vault folder must never become tracked, whatever it is named. Notes are
  private, and a tracked vault would push them to a public remote.

If a change would make any of these false, it is the wrong change.

---

## 7. Scheduling: hermes cron, not n8n

Anything recurring runs on hermes's own cron, driven by a tick script in
`scripts/hermes-cron/`.
`scripts/seed-cron.sh` copies those scripts to `~/.hermes/scripts/`, where
`hermes cron --script <name>` resolves them.

A tick script runs with `--no-agent`, so it is plain Python with no LLM in the
loop. Under `--deliver telegram`, **stdout is sent to the chat** and stderr is
not, so log to stderr and print only what the user should actually receive.

n8n is still in `docker-compose.yml` behind the `addon` compose profile, but it
owns no workflow and nothing depends on it.
Do not move scheduled work back into it.

---

## 8. Skills

Each hermes profile has its own skills directory:

```
~/.hermes/profiles/<agent>/skills/
```

Before starting a task, check whether a relevant skill exists for the active
profile:

```bash
find ~/.hermes/profiles/<name>/skills -name "SKILL.md"
```

Read the `SKILL.md` before proceeding.
Skills are per-profile here, not shared from a single directory, because each
agent is an isolated hermes profile.

Two sources are seeded into both agents by `scripts/hermes.sh`:

- `skills/` - shared, tracked in git.
- `skills-local/` - private, gitignored. Personal or proprietary content that
  must never be pushed. The data it reads lives outside this repo entirely.

---

## 9. Notes and the vault

Each agent owns one vault and writes plain Markdown into it.
Every note begins with front-matter, which is what the Obsidian Bases views on
the dashboard read:

```
---
type: task        # task | result | note
status: open      # open | doing | done
owner: <agent>
from: <agent>
created: YYYY-MM-DD
tags: []
---
```

Two Bases are seeded next to each dashboard:

- `tasks.base` - every note with `type: task` and `status` not `done`.
- `activity.base` - everything that is not a plain `note`, newest first.

There is no separate task syntax to remember: `status` and `type` in the
front-matter are what the Bases read.

The qdrant-indexer sidecar embeds everything written into the vault, so notes
become semantically searchable by the agent that owns them.

---

## 10. Secrets

- `.env`, `agents.conf`, `livesync-bridge/config.json`, `skills-local/`, and all
  runtime data folders (`n8n/`, `keirouter/`, `couchdb/`, `qdrant/`,
  `caddy/data/`, `vault*/`) are gitignored.
- Never commit real keys.
- `.env.example` and `agents.conf.example` are the templates.
- KeiRouter's master key must be a base64-encoded 32-byte value
  (`openssl rand -base64 32`), not an arbitrary string.
- `scripts/sync-env.sh` owns a managed block in `.env`. Everything it writes is
  derived config, never a secret. Do not put a secret inside that block; it is
  regenerated.

---

## 11. Production Ingress Map

On the VPS, Caddy terminates TLS and reverse-proxies each subdomain.
DNS A records must point at the VPS public IP before this works.
Caddy runs only under the `prod` compose profile:

```bash
docker compose --profile prod up -d
```

| Hostname | Upstream | Notes |
| --- | --- | --- |
| `ghiath.id` | static placeholder | nothing else live here yet |
| `couch.ghiath.id` | `couchdb:5984` | LiveSync endpoint, CouchDB's own auth |
| `ntfy.ghiath.id` | `ntfy:80` | reminder alarms, deny-all + token |
| `router.ghiath.id` | `keirouter:20180` | KeiRouter API and dashboard |
| `n8n.ghiath.id` | `n8n:5678` | only if the `addon` profile is started |

Caddy issues and renews Let's Encrypt certificates automatically the first time
each hostname is requested.
