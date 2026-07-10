# Ghiath - Personal Agentic Ecosystem

A local-first personal agentic ecosystem.
It runs a small set of AI agents backed by a long-term memory vault, an
automation router, a semantic search layer, and cross-device sync, all on your
own hardware.
The domain `ghiath.id` is reserved for the eventual VPS deployment; everything
here runs locally first.

## What this is

The system is built from a few cooperating pieces:

- **hermes-agent** (Nous Research) is the agent runtime.
  Each agent is a separate hermes profile with its own config, keys, memory, and
  gateway.
  There are three agents: `ippang` (lightweight personal assistant), `kuli`
  (software engineer buddy), and `pakprof` (researcher).
- **Obsidian** is the cognitive core and long-term memory.
  The vault lives at `obsidian-vault/`.
- **n8n** is the automation and routing nervous system.
  Inbound messages arrive here and n8n decides which agent handles them.
- **Qdrant** is a semantic search layer over the vault.
  A small indexer sidecar keeps it in sync.
- **CouchDB + Obsidian Self-hosted LiveSync** sync the vault to your phone and
  the VPS without paying for Obsidian Sync.
- **KeiRouter** is a self-hosted LLM gateway for cost and key management.
- **Caddy** is the reverse proxy that provides automatic HTTPS on subdomains,
  used only on the VPS.

hermes-agent does NOT run inside Docker in this setup.
It runs on the host via `hermes gateway start` per profile.
Do not try to dockerize it here; that is intentionally out of scope for now.

## Repository layout

```
ghiath/
- .gitignore
- .env.example
- README.md
- DEPLOY.md              VPS deployment and hardening checklist
- AGENT.md               rulebook for any AI agent working in this repo
- Makefile               make bootstrap / up / deploy / test / logs
- docker-compose.yml
- scripts/               bootstrap, couch-init, smoke-test, keirouter-connect
- caddy/                 Caddyfile for the VPS reverse proxy
- n8n-workflows/         importable router + vault-watch workflows (tracked)
- n8n/                   n8n state (gitignored)
- keirouter/             KeiRouter data (gitignored)
- couchdb/               CouchDB data (gitignored)
- qdrant/                Qdrant storage (gitignored)
- qdrant-indexer/        vault watcher sidecar (Dockerfile + indexer.py)
- obsidian-vault/        the Obsidian vault (gitignored)
  - .obsidian/
  - 000-Dashboard.md
  - projects/            kuli's folder
  - scratchpads/         ippang's folder
  - memory/              pakprof's folder
```

Hermes agent state lives at `~/.hermes/profiles/<name>/` per machine.
It is deliberately NOT part of this repo.

## Prerequisites

- Docker and Docker Compose.
- `openssl` for generating secrets.
- An Anthropic API key and/or an OpenRouter API key.
- Obsidian on desktop, and optionally on mobile, for the vault and LiveSync.
- macOS or Linux for the hermes host install.

## First run

Quickstart (does steps 1, 2, and CouchDB init for you):

```bash
make bootstrap   # generates secrets into .env, brings up the stack, inits CouchDB
make test        # smoke-test every service
```

Then create the n8n owner account, change the KeiRouter password, and set up the
hermes profiles (below). The manual walkthrough follows.

1. Copy the environment template and fill in real values:

   ```bash
   cp .env.example .env
   ```

   Generate strong secrets:

   ```bash
   # KeiRouter master key MUST be base64-encoded 32 bytes, not an arbitrary string
   openssl rand -base64 32     # -> KEIROUTER_MASTER_KEY
   openssl rand -hex 24        # -> N8N_ENCRYPTION_KEY
   openssl rand -hex 16        # -> COUCHDB_PASSWORD
   ```

   Put your `ANTHROPIC_API_KEY` and/or `OPENROUTER_API_KEY` in `.env` too.

2. Bring up the local stack:

   ```bash
   docker compose up -d
   ```

   This starts couchdb, qdrant, qdrant-indexer, keirouter, and n8n.
   Caddy is intentionally NOT started locally (see "Production" below).

   Service endpoints once up:

   | Service | URL |
   | --- | --- |
   | n8n | http://localhost:5678 |
   | Qdrant dashboard | http://localhost:6333/dashboard |
   | KeiRouter dashboard | http://localhost:20180 (default login password `keirouter`, change it) |
   | CouchDB | http://localhost:5984/_utils |

3. Configure CouchDB for Obsidian LiveSync (one time).
   The LiveSync plugin needs CORS enabled and a larger request size.
   With the stack up, run:

   ```bash
   source .env
   HOST=http://localhost:5984
   AUTH="-u ${COUCHDB_USER}:${COUCHDB_PASSWORD}"
   curl -s $AUTH -X PUT $HOST/_node/_local/_config/chttpd/require_valid_user -d '"true"'
   curl -s $AUTH -X PUT $HOST/_node/_local/_config/chttpd_auth/require_valid_user -d '"true"'
   curl -s $AUTH -X PUT $HOST/_node/_local/_config/httpd/WWW-Authenticate -d '"Basic realm=\"couchdb\""'
   curl -s $AUTH -X PUT $HOST/_node/_local/_config/httpd/enable_cors -d '"true"'
   curl -s $AUTH -X PUT $HOST/_node/_local/_config/cors/credentials -d '"true"'
   curl -s $AUTH -X PUT $HOST/_node/_local/_config/cors/origins -d '"app://obsidian.md,capacitor://localhost,http://localhost"'
   curl -s $AUTH -X PUT $HOST/_node/_local/_config/chttpd/max_http_request_size -d '"4294967296"'
   ```

4. Install the Obsidian "Self-hosted LiveSync" community plugin.
   Open `obsidian-vault/` as a vault in Obsidian on desktop.
   Install and enable "Self-hosted LiveSync" from Community Plugins.
   Point it at your CouchDB instance:
   - URI: `http://localhost:5984` (or `https://<your-couch-host>` on the VPS)
   - Username and password: the `COUCHDB_USER` / `COUCHDB_PASSWORD` from `.env`
   - Database name: pick one, for example `ghiath`
   Repeat on mobile once the VPS is reachable over HTTPS.

5. Install hermes on the host and set up each profile.
   The install is per machine and lives outside this repo.

   ```bash
   curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
   ```

   The three profiles and their models (already created on this machine):

   ```bash
   hermes profile create ippang
   ippang config set model.default deepseek/deepseek-v2-flash

   hermes profile create kuli
   kuli config set model.default anthropic/claude-opus-4-8    # orchestrator, plans
   kuli config set subagents.model anthropic/claude-sonnet-5  # subagents, execute

   hermes profile create pakprof
   pakprof config set model.default z-ai/glm-4.6
   ```

   Notes on the commands above:
   - hermes v0.18.2 has no `-p`/`--profile` global flag.
     Each profile becomes its own alias command (`ippang`, `kuli`, `pakprof`),
     so configure it as `ippang config set ...`.
   - There is no `model.planning` key.
     kuli's "strong model plans, fast model executes" is implemented with the
     orchestrator (`model.default`) plus a subagent model override
     (`subagents.model`).
   - Model slugs drift.
     After adding keys, confirm exact slugs from the live catalog with
     `hermes model --refresh` (or `<profile> model`) and adjust if a slug does
     not resolve.

   Start a profile's gateway when you want it reachable by n8n
   (default port 8642):

   ```bash
   ippang gateway start
   ```

## Routing through KeiRouter

KeiRouter is the single place that holds your real upstream provider keys, so
the agents never carry Anthropic or OpenRouter keys directly.
Each profile is already pointed at KeiRouter as a custom OpenAI-compatible
provider:

```
model.provider = custom
model.base_url = http://localhost:20180/v1
```

To finish the connection:

1. Open the KeiRouter dashboard at http://localhost:20180 and log in.
   The default password is `keirouter`; change it immediately.
2. Add your upstream provider key(s) there (Anthropic and/or OpenRouter).
   Confirm the exact model slugs KeiRouter exposes and adjust each profile's
   `model.default` to match if needed.
3. Mint a virtual key in the dashboard.
4. Push that virtual key into all three profiles:

   ```bash
   ./scripts/keirouter-connect.sh <keirouter-virtual-key>
   ```

5. Test one:

   ```bash
   ippang -z "say hello in three words"
   ```

Because keys live only in KeiRouter, you rotate them in one place, get
per-agent spend tracking, and benefit from its semantic cache.
Leave `ANTHROPIC_API_KEY` / `OPENROUTER_API_KEY` blank in `.env` unless you
deliberately bypass KeiRouter.

## How a request flows through the system

1. A message arrives (Telegram, Discord, a web form, or a cron trigger) and
   hits **n8n**.
2. n8n inspects the request and routes it to the right agent by calling that
   agent's local hermes gateway over its OpenAI-compatible API
   (`POST /v1/chat/completions` on port 8642).
   n8n plays the router role; there is no central lead agent.
3. The chosen agent reads and writes its owned folder in the Obsidian vault:
   `scratchpads/` for ippang, `projects/` for kuli, `memory/` for pakprof.
   An agent hands off to another agent by writing a note into that agent's
   folder; an n8n vault-watch workflow notices the new note and triggers the
   next agent.
4. The **qdrant-indexer** sidecar polls the vault, chunks changed Markdown,
   embeds it locally, and upserts it into **Qdrant**, so everything written
   becomes semantically searchable.
5. n8n logs the result back into the vault, and the Obsidian dashboard
   (`000-Dashboard.md`) surfaces open tasks and pipeline activity.
6. **CouchDB + LiveSync** replicate the whole vault to your phone and the VPS.

## n8n workflows

Two starting workflows live in `n8n-workflows/` and are already imported into
your local n8n:

- **Ghiath Router** (`router.json`): a `POST /webhook/ghiath` endpoint that
  inspects the message, picks an agent (research keywords go to pakprof, build
  keywords to kuli, everything else to ippang), calls that agent's hermes
  gateway, and returns the reply. The agent is told to persist its own output
  into its vault folder as part of the turn.
- **Ghiath Vault Watch** (`vault-watch.json`): watches `obsidian-vault/` for new
  `.md` files, works out which agent owns the folder the note landed in
  (`scratchpads` -> ippang, `projects` -> kuli, `memory` -> pakprof), and
  triggers that agent. This is the handoff mechanism: dropping a note in an
  agent's folder wakes that agent.

To (re)import after editing:

```bash
docker compose cp n8n-workflows/router.json n8n:/tmp/router.json
docker compose exec n8n n8n import:workflow --input=/tmp/router.json
```

Before activating them you must:

1. Start each profile's gateway on the port the workflow expects. Two gateways
   cannot share a port, so give each its own:

   ```bash
   ippang gateway start                 # 8642
   PORT=8643 kuli gateway start
   PORT=8644 pakprof gateway start
   ```

   Adjust the ports in the workflow's "Route" Code node if you use different
   ones. Confirm hermes honours the `PORT` override in your version; if not,
   set the gateway port in each profile's config.
2. Make sure the profiles are connected to KeiRouter (see "Routing through
   KeiRouter") so the gateway calls actually reach a model.
3. Open each workflow in the n8n editor (http://localhost:5678) and toggle it
   Active.

These are scaffolds, not finished automations. Verify the gateway URL/port and
the agent-selection rules against how you actually run things, then extend them
(Telegram/Discord triggers, richer routing, logging nodes).

## Production (VPS)

Caddy provides automatic HTTPS and is the only piece meant for the VPS.
It runs under the `prod` compose profile so it never starts during local dev.

Point four DNS A records at the VPS public IP before deploying:

```
ghiath.id
hermes.ghiath.id
n8n.ghiath.id
router.ghiath.id
```

Then, on the VPS:

```bash
docker compose --profile prod up -d
```

Ingress map (see `caddy/Caddyfile`):

| Hostname | Upstream | Notes |
| --- | --- | --- |
| `ghiath.id` | static `hello world` | placeholder for now |
| `hermes.ghiath.id` | `host.docker.internal:8642` | hermes runs on the host, not in compose |
| `n8n.ghiath.id` | `n8n:5678` | automation UI and webhooks |
| `router.ghiath.id` | `keirouter:20180` | KeiRouter API and dashboard |

Caddy issues and renews Let's Encrypt certificates automatically the first time
each hostname is requested.
No certbot and no cron job are needed.
Set `ACME_EMAIL` in `.env` on the VPS.

## Secrets

`.env` and all runtime data folders are gitignored.
Never commit real keys.
See `AGENT.md` for the full working rules in this repo.
