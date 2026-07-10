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
| `ippang` | Lightweight personal assistant. Fast, cheap, everyday tasks. | `obsidian-vault/scratchpads/` |
| `kuli` | Software engineer buddy. Plans with a strong model, executes with a fast one. | `obsidian-vault/projects/` |
| `pakprof` | Researcher. Deep reading, synthesis, long-term notes. | `obsidian-vault/memory/` |

Each profile's identity, owned folder, and handoff behaviour is also written
into its `SOUL.md` under `~/.hermes/profiles/<name>/`.

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

- `scratchpads/` - ippang's inbox and workspace.
- `projects/` - kuli's inbox and workspace.
- `memory/` - pakprof's inbox and workspace.

**A handoff is a file write.**
Agent A hands off to agent B by writing a note into agent B's folder.
An n8n vault-watch workflow (or hermes's own scheduling) notices the new note
and triggers agent B.

Example flow:

1. ippang receives a vague request and writes a research brief into `memory/`.
2. The vault-watch workflow notices the new note and triggers pakprof.
3. pakprof researches, writes its findings into `memory/`, and drops a note
   into `projects/` when something needs to be built.
4. The vault-watch workflow notices that note and triggers kuli.
5. kuli plans and implements, writing progress into `projects/`.

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
~/.hermes/profiles/ippang/skills/
~/.hermes/profiles/kuli/skills/
~/.hermes/profiles/pakprof/skills/
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
  `qdrant/`, `caddy/data/`, `obsidian-vault/`) are gitignored.
- Never commit real keys.
- `.env.example` is the template.
  Copy it to `.env` and fill in real values locally.
- KeiRouter's master key must be a base64-encoded 32-byte value
  (`openssl rand -base64 32`), not an arbitrary string.

---

## 7. Dashboard and Tasks

The vault dashboard lives at `obsidian-vault/000-Dashboard.md` and uses the
Obsidian Tasks plugin.
When you add a task anywhere in the vault, use this syntax so it shows up on the
dashboard:

```
- [ ] task description due: YYYY-MM-DD
```

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
