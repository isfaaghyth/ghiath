# Ghiath

> **Read this first.**
> Ghiath is built for light, non-extensive personal use, and nothing more.
> It is two small assistants, a notes vault, and enough glue to reach them from Telegram.
> There is no loop engineering here: no planner, no task graph, no retry or escalation logic, no orchestration across agents.
> If you push heavy or long-running agentic work through it, it will disappoint you, and that is by design rather than by neglect.
>
> **Want the serious version?**
> If you need an advanced technical agentic workflow with real loop engineering, use [**ghiath-loop**](https://github.com/isfaaghyth/ghiath-loop) instead.
> That is where the extensive, production-shaped work lives.

A self-hosted, local-first pair of AI assistants backed by a long-term memory vault, a semantic search layer, and cross-device sync, all running on your own hardware.

![Self-hosted](https://img.shields.io/badge/self--hosted-yes-success)
![Local-first](https://img.shields.io/badge/local--first-brightgreen)
![Docker Compose](https://img.shields.io/badge/Docker%20Compose-ready-2496ED?logo=docker&logoColor=white)

Everything runs locally first.
Deploying to a VPS behind your own domain is an opt-in step, not a requirement.

## Contents

- [The two agents](#the-two-agents)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration](#configuration)
  - [Agents](#agents)
  - [The confirmation gate](#the-confirmation-gate)
  - [Telegram bots](#telegram-bots)
  - [Routing through KeiRouter](#routing-through-keirouter)
  - [CouchDB and Obsidian LiveSync](#couchdb-and-obsidian-livesync)
- [Reminders](#reminders)
- [Updating without losing state](#updating-without-losing-state)
- [Private data and skills](#private-data-and-skills)
- [Deployment](#deployment)

## The two agents

Ghiath is exactly two agents, one per side of life.
They are fully isolated from each other: separate hermes profiles, separate vaults, separate Qdrant collections, separate Telegram bots.
There is no router, no lead agent, and no handoffs between them.

| Agent | Who talks to it | Model | Vault |
| --- | --- | --- | --- |
| **work** | You alone | GLM 5.1 | `vault-work/` |
| **home** | You and your partner | DeepSeek v4 Flash | `vault-home/` |

The **work** agent is the technical one.
It does the whole job itself: thinking, researching, planning, and executing.
Before it executes anything, it stops and asks you to confirm over Telegram.
See [the confirmation gate](#the-confirmation-gate).

The **home** agent is the household one.
Reminders, lists, plans, appointments, quick questions, journaling.
It is shared, so it never assumes which person it is talking to, and it cannot reach the work vault at all.

Names, models, ports, and vault folders are configuration.
Copy `agents.conf.example` to `agents.conf` and edit it; the shipped defaults are the neutral names above.

Ghiath used to run a team of three role agents behind an n8n router.
That was more machinery than a personal assistant needs, so it is gone.

## Architecture

```
   Telegram (work bot)                    Telegram (home bot)
            |                                      |
            v                                      v
   +------------------+                   +------------------+
   |   work agent     |                   |   home agent     |
   |   (hermes)       |                   |   (hermes)       |
   +--------+---------+                   +---------+--------+
            |                                       |
            v                                       v
   +------------------+                   +------------------+
   |   vault-work/    |                   |   vault-home/    |
   |   (Markdown)     |                   |   (Markdown)     |
   +--+------------+--+                   +--+------------+--+
      |            |                         |            |
 embeds|           |replicates         embeds|            |replicates
      v            v                         v            v
 +---------+  +----------+             +---------+  +----------+
 | Qdrant  |  | CouchDB  |             | Qdrant  |  | CouchDB  |
 |vault_work| |'ghiath'  |             |vault_home| |'ghiath-  |
 +---------+  +----------+             +---------+  |  home'   |
                   |                                +----------+
                   v                                     |
            your devices                                 v
                                              your + partner's devices

  Agent LLM calls  ->  KeiRouter (gateway, holds the provider keys)
  Reminder alarms  ->  hermes cron -> ntfy -> phone
  Public HTTPS     ->  Caddy (per-subdomain reverse proxy, VPS only)
```

The two columns never meet.
Separate Qdrant collections mean semantic search cannot cross, and separate CouchDB databases mean a household device syncing the home vault cannot see the work one.

Everything scheduled runs on **hermes's own cron**, not on an external automation engine.
n8n is still in `docker-compose.yml` as an optional add-on, but nothing depends on it and it does not start by default.

## Repository layout

```
ghiath/
- .env.example
- agents.conf.example   the two agents: names, models, ports, vaults
- docker-compose.yml
- Makefile              make bootstrap / up / agents / test / logs
- README.md
- DEPLOY.md             VPS deployment and hardening checklist
- AGENT.md              working rules for any AI agent in this repo
- REMINDERS.md          the reminder/alarm runbook
- scripts/              bootstrap, hermes provisioning, sync-env, smoke-test
    - hermes-cron/      tick scripts run by `hermes cron` (reminders)
- caddy/                Caddyfile for the VPS reverse proxy
- skills/               custom hermes skills seeded into both agents
- ntfy/                 ntfy push server config (server.yml; data gitignored)
- qdrant-indexer/       vault watcher sidecar (Dockerfile + indexer.py)
- vault-work/           the work vault (gitignored)
- vault-home/           the home vault (gitignored)
- n8n/ keirouter/ couchdb/ qdrant/    runtime data (gitignored)
```

Every folder matching `vault*/` is gitignored, so no note is ever pushed.

Hermes agent state lives at `~/.hermes/profiles/<name>/`, per machine, and is deliberately not part of this repo.

## Prerequisites

- Docker and Docker Compose.
- `openssl` for generating secrets.
- Obsidian on desktop, and optionally mobile, for the vaults and LiveSync.
- macOS or Linux for the hermes host install.
- An OpenRouter and/or Anthropic API key (added to KeiRouter, not committed).

## Quick start

```bash
cp agents.conf.example agents.conf   # name your agents, pick your models
make bootstrap                       # generate secrets, start the stack, init CouchDB
make test                            # smoke-test every service
```

`make bootstrap` starts couchdb, livesync-bridge, qdrant, both indexers, keirouter, and ntfy.
Caddy and n8n are not started (production and opt-in, respectively).

Service endpoints once up:

| Service | URL |
| --- | --- |
| KeiRouter dashboard | http://localhost:20180 (default password `keirouter`, change it) |
| Qdrant dashboard | http://localhost:6333/dashboard |
| CouchDB | http://localhost:5984/_utils |
| ntfy | http://localhost:8080 |

Then provision the two agents on the host:

```bash
./scripts/hermes.sh <keirouter-virtual-key>     # or: make agents K=<key>
```

Common tasks are in the Makefile; run `make help` for the full list.

## Configuration

### Agents

`agents.conf` is the single source of truth for both agents:

```bash
WORK_NAME="work"
WORK_MODEL="z-ai/glm-5.1"
WORK_PORT="8642"
WORK_VAULT="vault-work"
WORK_COLLECTION="vault_work"
WORK_CONFIRM_GATE="1"

HOME_NAME="home"
HOME_MODEL="deepseek/deepseek-v4-flash"
HOME_PORT="8645"
HOME_VAULT="vault-home"
HOME_COLLECTION="vault_home"
```

`scripts/hermes.sh` reads it to provision the hermes profiles, and `scripts/sync-env.sh` projects the vault and collection names into `.env`, where Docker Compose can read them.
After any change to `agents.conf`:

```bash
./scripts/sync-env.sh --write   # or: make sync-env
docker compose up -d
./scripts/hermes.sh             # or: make agents
```

hermes runs on the host, not in Docker. Install it once:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

`scripts/hermes.sh` is **idempotent and non-destructive**.
It creates a profile only if it is missing and otherwise reconfigures it in place, so sessions, memories, and Telegram bindings survive every run.
See [updating without losing state](#updating-without-losing-state).

Model slugs drift.
After adding provider keys to KeiRouter, confirm the exact slug with `hermes model --refresh` and adjust `agents.conf` if one does not resolve.

### The confirmation gate

The work agent will not execute a technical task until you say so.
This is written into its `SOUL.md` by `scripts/hermes.sh`, and it works like this:

1. **Plan.** It replies with what it understood, the exact steps it intends to take, and which files or services each step touches.
2. **Ask.** It ends with `Confirm to proceed? (reply "go")` and stops.
3. **Wait.** It does nothing until you answer. Anything that is not a clear go-ahead counts as "no".
4. **Execute.** On confirmation it carries out that plan, and only that plan. A step it did not list sends it back to step 1.

"Technical" means anything that changes state or runs code: editing files, running commands, installing packages, writing git operations, deploying, restarting services, mutating an API, changing configuration.
Reading, searching, summarizing, explaining, and planning are not gated, so questions still get answered immediately.

One confirmation covers one plan.
It never carries over to the next request and never becomes a standing permission.

Set `WORK_CONFIRM_GATE="0"` in `agents.conf` and re-run `./scripts/hermes.sh` to turn the gate off.
The home agent has no gate; it does not do technical work.

### Telegram bots

hermes has native Telegram support, so an agent is reachable from a bot with no extra service.
Each agent gets its **own** bot. That separation is the security boundary: the household bot has no path to the work vault.

1. Create two bots with [@BotFather](https://t.me/BotFather) and copy both tokens.
2. Put them in `.env`:

   ```
   WORK_TELEGRAM_BOT_TOKEN=123456:ABC-your-work-token
   HOME_TELEGRAM_BOT_TOKEN=789012:XYZ-your-home-token
   ```

3. Run `./scripts/hermes.sh`.
   It writes each token into the matching profile, and hermes connects the bot when that profile's gateway runs.

Lock them down after the first message.
Set `platforms.telegram.allowed_chats` in `~/.hermes/profiles/<agent>/config.yaml`: your chat id only for the work bot, yours and your partner's for the home bot.
Until you do, anyone who finds the bot can talk to it.

### Routing through KeiRouter

KeiRouter is the single place that holds your upstream provider keys, so the agents never carry them directly.
Both profiles are pointed at it as a custom OpenAI-compatible provider:

```
model.provider = custom
model.base_url = http://localhost:20180/v1
```

To finish the connection:

1. Open the KeiRouter dashboard, log in, and change the default password.
2. Add your upstream provider key(s), and confirm the model slugs KeiRouter exposes match `WORK_MODEL` and `HOME_MODEL`.
3. Mint a client API key (the `kr_...` value clients authenticate with; distinct from the `.env` master key):

   ```bash
   docker compose exec keirouter keirouter bootstrap -key-name ghiath-agents
   # prints a kr_... key once - copy it
   ```

4. Push it into both profiles:

   ```bash
   ./scripts/keirouter-connect.sh <kr_key>
   ```

5. Test: `work -z "say hello in three words"`.

Keys live only in KeiRouter, so you rotate them in one place and get per-agent spend tracking.
Leave `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY` blank in `.env` unless you deliberately bypass KeiRouter.

### CouchDB and Obsidian LiveSync

`make bootstrap` applies the CouchDB configuration LiveSync needs (CORS, valid-user auth, larger request size).
To re-apply it manually: `make couch-init`.

The `livesync-bridge` service is what connects the vault **on disk** (what the agents read and write) to CouchDB (what your devices sync).
Its config is generated by `scripts/sync-env.sh` into a gitignored file, because it holds the CouchDB password.

Install the Obsidian "Self-hosted LiveSync" community plugin, open the vault folder, and point the plugin at CouchDB:

- URI: `http://localhost:5984` locally, or `https://couch.example.com` on the VPS
- Username and password: `COUCHDB_USER` / `COUCHDB_PASSWORD` from `.env`
- Database name: `ghiath` for the work vault, `ghiath-home` for the home one (`LIVESYNC_DB` and `LIVESYNC_HOME_DB` in `.env`)

Keep those database names stable.
Renaming one orphans everything already synced under the old name.

Your partner's devices only ever get the `ghiath-home` database, which is what keeps the two vaults separate on their end too.

## Reminders

Ask either agent over Telegram to remind you of something.
The `reminders` skill (in `skills/`, seeded into both agents) picks a channel:

- **Alarm (ntfy)** - an urgent push that breaks through Do Not Disturb, repeats every minute, and keeps nagging until you tap **Acknowledge**. For things you must not miss.
- **Calendar (Google Calendar)** - a normal event with a reminder, created via the built-in `google-workspace` skill. For appointments and soft nudges.

If your request does not name a channel, the agent asks which you want.

The alarm path is entirely self-hosted and involves no LLM once the note is written:

```
you (Telegram) -> agent runs the "reminders" skill
   |- alarm    -> writes <vault>/reminders/<id>.md (status: scheduled)
   |               -> hermes cron runs reminder-tick.py every minute, fires ntfy
   |                  when due, re-nags until acknowledged, pings Telegram once
   |- calendar -> google-workspace skill creates the event (Google fires it)
```

`reminder-tick.py` scans **both** vaults, so either agent can set an alarm.

### The two ntfy topics

Each agent publishes to its own predefined topic. They are deliberately separate:

| Topic | Set by | Rings on | `.env` variable |
| --- | --- | --- | --- |
| `ghiath-work-alarm` | the work agent | your phone only | `NTFY_TOPIC` |
| `ghiath-home-alarm` | the home agent | both phones | `NTFY_HOME_TOPIC` |

Do not point both at one topic.
Separate topics plus ntfy's per-topic access control are what keep work alarms off your partner's phone; a single shared topic would leak every work reminder to both devices.

### Setting up ntfy on the phone

ntfy runs **deny-all**, so nothing works until you create accounts. There are three, and they do different jobs:

```bash
# 1. The publisher. Its token is what reminder-tick.py authenticates with.
#    Not used on any phone.
docker compose exec ntfy ntfy user add --role=admin ghiath   # sets a password
docker compose exec ntfy ntfy token add ghiath               # prints tk_...
# put that tk_... value in .env as NTFY_TOKEN

# 2. Your phone: access to both topics.
docker compose exec ntfy ntfy user add isfa
docker compose exec ntfy ntfy access isfa ghiath-work-alarm rw
docker compose exec ntfy ntfy access isfa ghiath-home-alarm rw

# 3. Your partner's phone: the household topic and nothing else.
docker compose exec ntfy ntfy user add rumah
docker compose exec ntfy ntfy access rumah ghiath-home-alarm rw
```

Check the result with `docker compose exec ntfy ntfy access`.
The `rumah` account should show only `ghiath-home-alarm`.

Then, on each phone:

1. Install **ntfy** from the Play Store or App Store.
2. Open **Settings, Default server** and set it to your public URL, e.g. `https://ntfy.ghiath.id`. This must be the HTTPS domain, not the loopback address.
3. Open **Settings, Manage users**, then **Add user**: the server URL, plus the username and password from above (`isfa` on your phone, `rumah` on your partner's).
4. Subscribe to the topics that account is allowed to read:
   - your phone: `ghiath-work-alarm` **and** `ghiath-home-alarm`
   - your partner's phone: `ghiath-home-alarm` only
5. On **each** subscription, open its settings and enable **"Override Do Not Disturb"**, then pick a loud sound. This is the step that turns a normal push into an alarm you cannot sleep through. It is per subscription, so it must be done for both on your phone.

If a subscription shows an authentication error, that account has no `access` grant for that topic. Re-run the matching `ntfy access` command.

Full step-by-step (DNS, registering the cron job, optional calendar OAuth) is in **[REMINDERS.md](REMINDERS.md)**.

## Updating without losing state

Deploying an update must never cost you a Telegram login, a session, or a note.
Three things guarantee that:

- **`scripts/hermes.sh` never deletes a profile.**
  It creates one only when missing and otherwise reconfigures in place, so `sessions/`, `memories/`, and the per-profile `.env` holding the Telegram token are all preserved.
  The role text lives inside a marked block in `SOUL.md` that is replaced whole, so re-running updates the role without duplicating it.
  The destructive path exists but is opt-in and interactive: `./scripts/hermes.sh --reset`.
- **Vault seeding is additive.**
  An existing file is never overwritten. `make agents` on a vault full of notes only ever adds the scaffolding that is missing.
- **Every vault folder is gitignored** via the `vault*/` pattern, so a `git pull` cannot clobber your notes and a `git push` cannot leak them.

The normal update, safe to run on a live box:

```bash
git pull
make sync-env          # re-project agents.conf into .env
docker compose up -d   # recreate containers; bind-mounted data is untouched
make agents            # reconfigure the agents in place
make test
```

`make reinstall` (`scripts/force-reinstall.sh`) offers heavier Docker-side resets.
Even its most destructive level only touches Docker state; the host-side agent profiles and the vaults survive.

### Migrating from the three-agent setup

This is a one-time migration, needed only on a box that ran the older
assistant/engineer/researcher version. The routine update above is enough afterwards.

**`agents.conf` and `.env` are gitignored, so `git pull` does not migrate them.**
`scripts/hermes.sh` and `scripts/sync-env.sh` both refuse to run against a stale
`agents.conf` rather than silently provisioning new empty profiles, so a mistake
here fails loudly instead of leaving your bot dark.

```bash
cd ~/ghiath
git pull

# 1. Rewrite agents.conf in the WORK_/HOME_ format. Reuse the EXISTING profile
#    name for WORK_NAME: that is what preserves its sessions and Telegram
#    binding. Reuse the existing folder names for the vaults.
$EDITOR agents.conf

# 2. Project it into .env and the LiveSync bridge config.
make sync-env

# 3. Add the second ntfy topic and, if you have not already, the two bot tokens.
#    NTFY_TOPIC changes name in this version, so update it too.
$EDITOR .env
#   NTFY_TOPIC=ghiath-work-alarm
#   NTFY_HOME_TOPIC=ghiath-home-alarm
#   WORK_TELEGRAM_BOT_TOKEN=...     (or keep the old TELEGRAM_BOT_TOKEN name)
#   HOME_TELEGRAM_BOT_TOKEN=...

# 4. Recreate the stack. n8n is now an add-on and will not start; if it is
#    currently running, stop it explicitly.
docker compose --profile prod up -d
docker compose --profile addon stop n8n     # only if it was running

# 5. Reconfigure the agents in place and create the home agent.
make agents K=<keirouter-key>

# 6. The vault-tick cron job no longer exists; its script was removed.
hermes cron list
hermes cron delete ghiath-vault             # if it is listed

# 7. Re-seed the reminder tick and confirm its job is still registered.
make seed-cron
hermes cron list

make test
```

Then finish on the phone side, because the work topic was renamed and the
household topic is new:

- Create the per-phone ntfy accounts and grants, and re-subscribe both phones to the topics they are allowed to read. See [setting up ntfy on the phone](#setting-up-ntfy-on-the-phone).
- Message the home bot once, then add both chat ids to `platforms.telegram.allowed_chats` in the home profile's `config.yaml`.

Two things are intentionally left alone, because deleting them is not reversible
and neither is in the way:

- **The retired profiles.** `hermes.sh` prints the exact command if it finds any. Remove them only once you are satisfied the new setup works:
  `<name> gateway uninstall && hermes profile delete -y <name>`
- **The old n8n workflows and their data.** If you had imported the router, vault-watch, vault-notify or reminder workflows, deactivate them in the n8n UI so nothing fires twice.

## Private data and skills

Some knowledge is personal or proprietary and must never land in this repo.
The convention keeps two things machine-local:

- **The data** lives outside this repo entirely: clone it somewhere like `~/private-data/<name>` on the host.
  Agents run on the host, so they can read that path directly.
- **The skill** that reads it lives in `skills-local/` (gitignored).
  `hermes.sh` seeds `skills-local/` into both agents exactly like the shared `skills/`, so a private skill is durable across re-provisions yet never pushed.

This mirrors how secrets are handled elsewhere: `.env`, `agents.conf`, and `livesync-bridge/config.json` are all gitignored while their `*.example` templates are tracked.

## Deployment

Caddy provides automatic HTTPS and is the only piece meant for the VPS.
It runs under the `prod` compose profile, so it never starts during local development.

Point your DNS A records at the VPS public IP before deploying, then:

```bash
make deploy      # docker compose --profile prod up -d, then CouchDB init
```

Ingress map (see `caddy/Caddyfile`):

| Hostname | Upstream | Notes |
| --- | --- | --- |
| `example.com` | static placeholder | nothing else live here yet |
| `couch.example.com` | `couchdb:5984` | LiveSync endpoint, uses CouchDB's own auth |
| `ntfy.example.com` | `ntfy:80` | reminder alarms; deny-all, token required |
| `router.example.com` | `keirouter:20180` | dashboard behind basic_auth |
| `n8n.example.com` | `n8n:5678` | only if you start the `addon` profile |

Caddy issues and renews Let's Encrypt certificates automatically.
Every other service binds to localhost, so only Caddy is publicly reachable.
The full deployment and hardening checklist is in [DEPLOY.md](DEPLOY.md).
