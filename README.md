# Ghiath

A self-hosted, local-first agentic ecosystem: a small team of AI agents backed by
a long-term memory vault, an automation router, a semantic search layer, and
cross-device sync, all running on your own hardware.

![Self-hosted](https://img.shields.io/badge/self--hosted-yes-success)
![Local-first](https://img.shields.io/badge/local--first-brightgreen)
![Docker Compose](https://img.shields.io/badge/Docker%20Compose-ready-2496ED?logo=docker&logoColor=white)

Everything runs locally first. Deploying to a VPS behind your own domain is an
opt-in step, not a requirement.

## Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [How a request flows](#how-a-request-flows)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration](#configuration)
  - [CouchDB and Obsidian LiveSync](#couchdb-and-obsidian-livesync)
  - [Hermes profiles](#hermes-profiles)
  - [Routing through KeiRouter](#routing-through-keirouter)
  - [Telegram bot](#telegram-bot)
- [n8n workflows](#n8n-workflows)
- [Deployment](#deployment)

## Overview

Ghiath is assembled from a few cooperating, self-hostable pieces:

| Component | Role |
| --- | --- |
| [hermes-agent](https://hermes-agent.nousresearch.com) | The agent runtime. Each agent is an isolated profile with its own config, keys, memory, and gateway. |
| [Obsidian](https://obsidian.md) | The cognitive core and long-term memory. The vault is a folder of Markdown files. |
| [n8n](https://n8n.io) | The automation and routing nervous system. Inbound messages arrive here and it decides which agent responds. |
| [Qdrant](https://qdrant.tech) | A semantic search layer over the vault, kept in sync by a small indexer sidecar. |
| CouchDB + [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) | Sync the vault across your devices and the VPS, without a paid Obsidian Sync subscription. |
| KeiRouter | A self-hosted LLM gateway for cost tracking and key management. |
| [Caddy](https://caddyserver.com) | Reverse proxy with automatic HTTPS. Used only on the VPS. |

The three agents:

- `ippang` - a lightweight personal assistant. Owns `obsidian-vault/scratchpads/`.
- `kuli` - a software engineer buddy that plans with a strong model and executes
  with a fast one. Owns `obsidian-vault/projects/`.
- `pakprof` - a researcher. Owns `obsidian-vault/memory/`.

There is no central lead agent; n8n plays the router. Agents hand off to each
other by writing a note into the target agent's folder.

> hermes-agent does not run inside Docker here. It runs on the host via
> `hermes gateway start` per profile. Dockerizing it is intentionally out of
> scope for now.

## Architecture

```
                inbound (Telegram / Discord / web / cron)
                                 |
                                 v
                           +-----------+
                           |    n8n    |   router + vault-watch workflows
                           +-----+-----+
                                 | OpenAI-compatible call
                                 v
            +--------------------+---------------------+
            |         hermes agents (on the host)      |
            |     ippang        kuli        pakprof     |
            +----+----------------+----------------+----+
                 |   read / write owned vault folders   |
                 v                                       v
             +-------------------------------------------+
             |          Obsidian vault (Markdown)         |
             |   scratchpads/    projects/    memory/     |
             +--------+----------------------+-----------+
              embeds  |                       |  replicates
                      v                       v
                +-----------+          +--------------+
                |  Qdrant   |          |   CouchDB    |--> phone / desktop / VPS
                | semantic  |          |  (LiveSync)  |
                +-----------+          +--------------+

  Agent LLM calls  ->  KeiRouter (gateway, holds the provider keys)
  Public HTTPS     ->  Caddy (per-subdomain reverse proxy, on the VPS only)
```

## How a request flows

1. A message arrives (Telegram, Discord, a web form, or a cron trigger) and hits
   **n8n**.
2. n8n inspects it and routes to the right agent by calling that agent's hermes
   gateway over its OpenAI-compatible API (`POST /v1/chat/completions`, port 8642).
3. The chosen agent reads and writes its owned vault folder. To hand off, it
   writes a note into another agent's folder; an n8n vault-watch workflow notices
   the new note and triggers that agent.
4. The **qdrant-indexer** sidecar polls the vault, chunks changed Markdown, embeds
   it locally, and upserts it into **Qdrant**, so everything written becomes
   semantically searchable.
5. Results are logged back into the vault, and the Obsidian dashboard
   (`000-Dashboard.md`) surfaces open tasks and pipeline activity.
6. **CouchDB + LiveSync** replicate the whole vault to every device.

## Repository layout

```
ghiath/
- .env.example
- docker-compose.yml
- Makefile               make bootstrap / up / deploy / test / logs
- README.md
- DEPLOY.md              VPS deployment and hardening checklist
- AGENT.md               working rules for any AI agent in this repo
- scripts/               bootstrap, couch-init, smoke-test, keirouter-connect
- caddy/                 Caddyfile for the VPS reverse proxy
- n8n-workflows/         importable router + vault-watch workflows (tracked)
- qdrant-indexer/        vault watcher sidecar (Dockerfile + indexer.py)
- obsidian-vault/        the Obsidian vault (gitignored)
    - 000-Dashboard.md
    - scratchpads/       ippang's folder
    - projects/          kuli's folder
    - memory/            pakprof's folder
- n8n/ keirouter/ couchdb/ qdrant/    runtime data (gitignored)
```

Hermes agent state lives at `~/.hermes/profiles/<name>/`, per machine, and is
deliberately not part of this repo.

## Prerequisites

- Docker and Docker Compose.
- `openssl` for generating secrets.
- Obsidian on desktop, and optionally mobile, for the vault and LiveSync.
- macOS or Linux for the hermes host install.
- An Anthropic and/or OpenRouter API key (added to KeiRouter, not committed).

## Quick start

```bash
cp .env.example .env      # optional: bootstrap generates secrets for you
make bootstrap            # generate secrets, start the stack, initialize CouchDB
make test                 # smoke-test every service
```

`make bootstrap` starts couchdb, qdrant, qdrant-indexer, keirouter, and n8n.
Caddy is not started locally (it is production only).

Service endpoints once up:

| Service | URL |
| --- | --- |
| n8n | http://localhost:5678 |
| Qdrant dashboard | http://localhost:6333/dashboard |
| KeiRouter dashboard | http://localhost:20180 (default password `keirouter`, change it) |
| CouchDB | http://localhost:5984/_utils |

Then create the n8n owner account, change the KeiRouter password, and set up the
hermes profiles as described below.

Common tasks are in the Makefile - run `make help` for the full list.

## Configuration

### CouchDB and Obsidian LiveSync

`make bootstrap` already applies the CouchDB configuration LiveSync needs (CORS,
valid-user auth, larger request size). To re-apply it manually:

```bash
make couch-init
```

Then install the Obsidian "Self-hosted LiveSync" community plugin, open
`obsidian-vault/` as a vault, and point the plugin at CouchDB:

- URI: `http://localhost:5984` locally, or `https://couch.example.com` on the VPS
- Username and password: `COUCHDB_USER` / `COUCHDB_PASSWORD` from `.env`
- Database name: any name, the same one on every device

Repeat on mobile once the VPS is reachable over HTTPS.

### Hermes profiles

hermes runs on the host, not in Docker. After installing it once:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

the fastest path is the setup script, which resets and reprovisions all three
profiles (models, KeiRouter wiring, roles, Telegram, and gateways) idempotently:

```bash
./scripts/hermes.sh <keirouter-virtual-key>
```

To do it by hand instead, the equivalent per-profile commands are:

```bash
hermes profile create ippang
ippang config set model.default deepseek/deepseek-v2-flash

hermes profile create kuli
kuli config set model.default anthropic/claude-opus-4-8      # orchestrator, plans
kuli config set subagents.model anthropic/claude-sonnet-5    # subagents, execute

hermes profile create pakprof
pakprof config set model.default z-ai/glm-4.6
```

Notes:

- Each profile becomes its own alias command (`ippang`, `kuli`, `pakprof`), so
  you configure it as `ippang config set ...`. There is no `-p` global flag.
- There is no `model.planning` key. kuli's "strong model plans, fast model
  executes" split is done with the orchestrator (`model.default`) plus a subagent
  model override (`subagents.model`).
- Model slugs drift. After adding keys, confirm exact slugs from the live catalog
  with `hermes model --refresh` and adjust if one does not resolve.

Start a profile's gateway when you want it reachable by n8n (default port 8642):

```bash
ippang gateway start
```

### Routing through KeiRouter

KeiRouter is the single place that holds your upstream provider keys, so the
agents never carry Anthropic or OpenRouter keys directly. Each profile is already
pointed at KeiRouter as a custom OpenAI-compatible provider:

```
model.provider = custom
model.base_url = http://localhost:20180/v1
```

To finish the connection:

1. Open the KeiRouter dashboard, log in, and change the default password.
2. Add your upstream provider key(s), and confirm the model slugs KeiRouter
   exposes match each profile's `model.default`.
3. Mint a virtual key.
4. Push it into all three profiles:

   ```bash
   ./scripts/keirouter-connect.sh <keirouter-virtual-key>
   ```

5. Test one: `ippang -z "say hello in three words"`.

Keys live only in KeiRouter, so you rotate them in one place and get per-agent
spend tracking and a semantic cache. Leave `ANTHROPIC_API_KEY` /
`OPENROUTER_API_KEY` blank in `.env` unless you deliberately bypass KeiRouter.

### Telegram bot

hermes has native Telegram support, so an agent can be reached from a Telegram
bot with no extra service. One bot maps to one front-door agent (ippang by
default); it answers directly and hands off to kuli or pakprof through the vault.

1. In Telegram, message [@BotFather](https://t.me/BotFather), run `/newbot`, and
   copy the token it gives you.
2. Put it in `.env`:

   ```
   TELEGRAM_BOT_TOKEN=123456:ABC-your-token
   ```

3. Run the setup script (also covers cleanup and profile config):

   ```bash
   ./scripts/hermes.sh <keirouter-virtual-key>
   ```

   It writes the token into the front-door profile's `.env` and, when that
   profile's gateway runs, hermes connects the bot. Message your bot to test.

Lock it down after the first message: set `platforms.telegram.allowed_chats` in
`~/.hermes/profiles/ippang/config.yaml` to your own chat id, so only you can use
the bot. Change the front-door agent with `TELEGRAM_PROFILE=kuli ./scripts/hermes.sh`.

## n8n workflows

Two starting workflows live in `n8n-workflows/` and are imported automatically:

- **Router** (`router.json`): a `POST /webhook/ghiath` endpoint that inspects the
  message, picks an agent (research keywords go to pakprof, build keywords to
  kuli, everything else to ippang), calls that agent's gateway, and returns the
  reply. The agent persists its own output into its vault folder.
- **Vault Watch** (`vault-watch.json`): watches `obsidian-vault/` for new `.md`
  files and triggers the agent that owns the folder the note landed in. This is
  the handoff mechanism.

To re-import after editing:

```bash
docker compose cp n8n-workflows/router.json n8n:/tmp/router.json
docker compose exec n8n n8n import:workflow --input=/tmp/router.json
```

Before activating them, start each profile's gateway on its own port (two
gateways cannot share one), connect the profiles to KeiRouter, then toggle each
workflow Active in the editor:

```bash
ippang gateway start                 # 8642
PORT=8643 kuli gateway start
PORT=8644 pakprof gateway start
```

These are scaffolds, not finished automations. Verify the gateway URLs/ports and
the routing rules against your setup, then extend them (Telegram/Discord
triggers, richer routing, logging).

## Deployment

Caddy provides automatic HTTPS and is the only piece meant for the VPS. It runs
under the `prod` compose profile, so it never starts during local development.

Point five DNS A records at the VPS public IP before deploying:

```
example.com  hermes.example.com  n8n.example.com  router.example.com  couch.example.com
```

Then, on the VPS:

```bash
make deploy      # docker compose --profile prod up -d, then CouchDB init
```

Ingress map (see `caddy/Caddyfile`):

| Hostname | Upstream | Notes |
| --- | --- | --- |
| `example.com` | static placeholder | nothing else live here yet |
| `hermes.example.com` | `host.docker.internal:8642` | hermes runs on the host; uses its own gateway auth |
| `n8n.example.com` | `n8n:5678` | automation UI and webhooks; uses n8n's owner-account login |
| `router.example.com` | `keirouter:20180` | dashboard behind basic_auth; the `/v1` API is exempt so agents can use Bearer keys |
| `couch.example.com` | `couchdb:5984` | LiveSync endpoint, uses CouchDB's own auth |

Caddy issues and renews Let's Encrypt certificates automatically. Every other
service binds to localhost, so only Caddy is publicly reachable. The full
deployment and hardening checklist is in [DEPLOY.md](DEPLOY.md).
