# Ghiath - VPS Deployment and Hardening

This is the checklist for taking Ghiath from local to production on your VPS.
Do the steps in order.
Nothing here is safe to skip if the box is reachable from the public internet.

## Security model in one paragraph

Only Caddy is public (ports 80 and 443).
Every other service binds to `127.0.0.1` inside the VPS, so the only way in
from outside is through a Caddy site block.
Each service provides its own authentication: the KeiRouter dashboard login,
CouchDB's user/password, ntfy's deny-all plus tokens, and n8n's owner account if
you start that add-on.
Caddy adds HTTP basic_auth only in front of the KeiRouter dashboard, as an extra
human-facing gate; the KeiRouter `/v1` API is exempt so agents can authenticate
with their Bearer virtual key.
basic_auth is deliberately not placed in front of n8n (it breaks the SPA and
re-prompts on navigation) or the KeiRouter API (it collides with Bearer tokens).
Qdrant is never exposed; reach it over an SSH tunnel when you need it.

The agents themselves are not publicly reachable at all.
They are driven over Telegram, and their gateways are Telegram pollers rather
than inbound HTTP endpoints, so there is nothing to expose.

## 1. Provision the box

```bash
# Docker + compose
curl -fsSL https://get.docker.com | sh

# Firewall: allow only SSH and web
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

Confirm no other ports are open:

```bash
sudo ufw status verbose
```

## 2. DNS

Point these A records at the VPS public IP:

```
ghiath.id
router.ghiath.id
couch.ghiath.id
ntfy.ghiath.id
n8n.ghiath.id      # only if you plan to start the addon profile
```

Wait for propagation (`dig +short couch.ghiath.id` should return the VPS IP)
before starting Caddy, otherwise Let's Encrypt issuance will fail and rate-limit.

## 3. Clone and configure

```bash
git clone <your-private-repo-url> ghiath
cd ghiath
cp .env.example .env
cp agents.conf.example agents.conf   # then edit: names, models, vaults
```

Fill `.env` with production values:

- `ENVIRONMENT=production`
- Strong `KEIROUTER_MASTER_KEY` (`openssl rand -base64 32`)
- Strong `N8N_ENCRYPTION_KEY` (`openssl rand -hex 24`) - keep this stable, it
  decrypts saved n8n credentials if you ever start that add-on
- Strong `COUCHDB_PASSWORD` (`openssl rand -hex 16`)
- Both Telegram bot tokens: `WORK_TELEGRAM_BOT_TOKEN` and
  `HOME_TELEGRAM_BOT_TOKEN`
- `ACME_EMAIL=you@example.com`
- `BASIC_AUTH_USER` and `BASIC_AUTH_HASH`:

  ```bash
  docker run --rm caddy:2 caddy hash-password --plaintext 'your-strong-password'
  ```

  Paste the output as `BASIC_AUTH_HASH`.
- n8n public URL settings:

  ```
  N8N_HOST=n8n.ghiath.id
  N8N_PROTOCOL=https
  N8N_WEBHOOK_URL=https://n8n.ghiath.id/
  N8N_SECURE_COOKIE=true
  ```

Leave `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY` blank and put those keys in
KeiRouter instead (see README, "Routing through KeiRouter").

## 4. Bring up the stack

```bash
make deploy      # docker compose --profile prod up -d, then CouchDB init
```

Or manually:

```bash
docker compose --profile prod up -d
# then run the CouchDB init block (see README step 3)
```

Watch Caddy get its certificates:

```bash
docker compose logs -f caddy
```

## 5. First-load hardening of each service

- **KeiRouter**: open `https://router.ghiath.id`, get past basic_auth, log in
  with the default password `keirouter`, and change it at once. Add your
  provider keys here.
- **ntfy**: it starts deny-all. Create the user and publish token before
  anything can use it (see REMINDERS.md).
- **n8n** (only if you started the `addon` profile): open
  `https://n8n.ghiath.id` and immediately create the owner account. Until that
  account exists, do not share the URL.
- **Telegram**: message each bot once, then set
  `platforms.telegram.allowed_chats` in `~/.hermes/profiles/<agent>/config.yaml`
  so only the intended chats can reach it. Until you do, anyone who finds the
  bot can talk to it, and the work bot can run commands.

## 6. hermes on the VPS

hermes runs on the host, not in Docker. Either install fresh and provision:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
./scripts/hermes.sh <keirouter-virtual-key>
```

or move your existing profiles over from your Mac, which preserves their
sessions and memories:

```bash
# on the Mac
hermes profile export work --output work.tar
scp work.tar user@vps:~/
# on the VPS
hermes profile import work.tar
./scripts/hermes.sh <keirouter-virtual-key>   # safe: reconfigures in place
```

`scripts/hermes.sh` is non-destructive, so running it against imported profiles
updates their model, role, and skills without discarding what came with them.

Then install the gateways (this is what connects the Telegram bots):

```bash
PORT=8642 work gateway install --force --start-now --start-on-login
PORT=8645 home gateway install --force --start-now --start-on-login
```

`./scripts/hermes.sh` already does this unless you pass `INSTALL_GATEWAYS=0`.

## 7. Point Obsidian LiveSync at the VPS

In the LiveSync plugin on desktop and mobile, set the URI to
`https://couch.ghiath.id`, with the CouchDB user and password from `.env`, and
the same database name you used locally: `ghiath` for the work vault,
`ghiath-home` for the household one.

Your partner's devices get the `ghiath-home` database only. That is what keeps
the work vault off their phone.

## Reaching internal services

Qdrant and anything else on loopback are reached with an SSH tunnel, not a
public URL:

```bash
ssh -L 6333:localhost:6333 user@vps
# then open http://localhost:6333/dashboard on your laptop
```

## Ongoing

- Rotate `BASIC_AUTH_HASH` and the KeiRouter dashboard password periodically.
- Back up `couchdb/` and both vault folders (or rely on LiveSync replication to
  your devices).
- `docker compose pull && make deploy` to update images; `N8N_ENCRYPTION_KEY`
  must not change across updates.

### Updating a live box

The routine update never costs you a Telegram session or a note:

```bash
cd ~/ghiath
git pull
make sync-env                          # re-project agents.conf into .env
docker compose --profile prod up -d    # recreate containers, data untouched
make agents K=<keirouter-key>          # reconfigure the agents in place
make test
```

`make agents` runs `scripts/hermes.sh`, which never deletes a profile. Sessions,
memories, and the Telegram bot bindings survive.
The one command that does discard them is `./scripts/hermes.sh --reset`, which
is interactive and asks for confirmation first.
