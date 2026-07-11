# Ghiath - Agent Guidelines

These are the rules for any AI agent working inside this repository (the Ghiath
personal agentic ecosystem).
They adapt Isfa's global agent guidelines to this specific project.
The agents, directories, and handoff mechanism here are different from the
`/opt/data/.a2a/` setup used by Isfa's other agents, so follow this file, not
that one, when working in this repo.

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

## 2. The Agents

There is no single lead agent in this project unless Isfa asks for one later.
n8n plays the role the TPM plays in Isfa's other setup: it is the router that
decides which profile handles an incoming request.
Each agent is a separate hermes profile with its own home directory, config,
keys, memory, and gateway.

| Agent | Role | Owns vault folder |
| --- | --- | --- |
| `assistant` | Lightweight everyday assistant. Fast, cheap, everyday tasks. | `vault/scratchpads/` |
| `engineer` | Software engineer buddy. Plans with a strong model, executes with a fast one. | `vault/projects/` |
| `researcher` | Researcher. Deep reading, synthesis, long-term notes. | `vault/memory/` |

Each profile's identity, owned folder, and handoff behaviour is also written
into its `SOUL.md` under `~/.hermes/profiles/<name>/`.

Agent names, models, vault folder names, and ports are configurable: copy
`agents.conf.example` to `agents.conf` and edit it. The shipped defaults are the
neutral names above.

---

## 3. Routing and Orchestration

- Inbound messages (Telegram, Discord, web, cron) arrive at **n8n**.
- n8n inspects the request and routes it to the appropriate hermes profile by
  calling that profile's local gateway (default port 8642) over its
  OpenAI-compatible API (`POST /v1/chat/completions`).
- The chosen agent reads and writes its owned vault folder, then n8n logs the
  result back into the vault.
- There is no TPM and no central task board. Routing lives in n8n workflows.

---

## 4. Handoffs (the Obsidian vault, not a message bus)

This project does not use a separate `/opt/data/.a2a/` inbox/contracts/board
structure.
The handoff mechanism IS the Obsidian vault.
Each agent owns one folder, and that folder is that agent's inbox and workspace:

- `scratchpads/` - the assistant's inbox and workspace.
- `projects/` - the engineer's inbox and workspace.
- `memory/` - the researcher's inbox and workspace.

**A handoff is a file write.**
Agent A hands off to agent B by writing a note into agent B's folder.
An n8n vault-watch workflow (or hermes's own scheduling) notices the new note
and triggers agent B.

**Every note carries front-matter.**
This is what makes handoffs loop-safe and powers the Obsidian Bases views on
the dashboard.
Each Markdown note an agent writes MUST begin with:

```
---
type: task        # task | brief | result | note
status: open      # open | doing | done
owner: <agent>    # the agent who should act next
from: <agent>     # who created the note
created: YYYY-MM-DD
tags: []
---
```

The vault-watch workflow only triggers on notes whose `status` is `open`.
An agent's own output is written as `type: result` with `status: done`, so it
never re-triggers itself.
When an agent picks up an open note it sets `status: doing`, then `done` when
finished.
A note with no front-matter is treated as a human-created open task.

Example flow:

1. The assistant receives a vague request and writes a research brief into `memory/`.
2. The vault-watch workflow notices the new note and triggers the researcher.
3. The researcher researches, writes its findings into `memory/`, and drops a note
   into `projects/` when something needs to be built.
4. The vault-watch workflow notices that note and triggers the engineer.
5. The engineer plans and implements, writing progress into `projects/`.

Keep handoff notes plain and self-contained.
The note itself is the contract: state what you did, what you need, and which
agent should pick it up next.

The same qdrant-indexer sidecar that powers semantic search also watches the
vault, so anything written for a handoff is embedded into Qdrant and becomes
searchable by every agent.

---

## 5. Skills

Each hermes profile has its own skills directory:

```
~/.hermes/profiles/assistant/skills/
~/.hermes/profiles/engineer/skills/
~/.hermes/profiles/researcher/skills/
```

Before starting a task, check whether a relevant skill exists for the active
profile:

```bash
find ~/.hermes/profiles/<name>/skills -name "SKILL.md"
```

Read the `SKILL.md` before proceeding.
Skills are per-profile here, not shared from a single `/opt/data/skills/`
directory, because each agent is an isolated hermes profile.

---

## 6. Secrets

- `.env` and all runtime data folders (`n8n/`, `keirouter/`, `couchdb/`,
  `qdrant/`, `caddy/data/`, `vault/`) are gitignored.
- Never commit real keys.
- `.env.example` is the template.
  Copy it to `.env` and fill in real values locally.
- KeiRouter's master key must be a base64-encoded 32-byte value
  (`openssl rand -base64 32`), not an arbitrary string.

---

## 7. Dashboard and Tasks

The vault dashboard lives at `vault/000-Dashboard.md`.
It is intentionally lightweight: a quick-capture area plus embedded Obsidian
Bases views.
The observability comes from the Bases, not from the note itself, so you rarely
edit the dashboard by hand.

Two Bases are seeded alongside it:

- `tasks.base` - every note with `type: task` and `status` not `done`, i.e. the
  open work across `scratchpads/`, `projects/`, and `memory/`.
- `activity.base` - everything the agents have produced (anything that is not a
  plain `note`), newest first.

Both query the front-matter defined in section 4, so the single requirement is
that every note carries that front-matter.
There is no separate task syntax to remember: `status` and `type` in the
front-matter are what the Bases read.

---

## 8. Production Ingress Map

On the VPS, Caddy terminates TLS and reverse-proxies each subdomain.
Four DNS A records must point at the VPS public IP before this works.

| Hostname | Upstream | Notes |
| --- | --- | --- |
| `ghiath.id` | static `respond "hello world"` | placeholder for now |
| `hermes.ghiath.id` | `host.docker.internal:8642` | hermes runs host-only; gateway default port 8642 |
| `n8n.ghiath.id` | `n8n:5678` | automation UI and webhooks |
| `router.ghiath.id` | `keirouter:20180` | KeiRouter API and dashboard (same port in Docker) |

Caddy issues and renews Let's Encrypt certificates automatically the first time
each hostname is requested.
It runs only under the `prod` compose profile:

```bash
docker compose --profile prod up -d
```
