# Ghiath - VPS Deployment and Hardening

This is the checklist for taking Ghiath from local to production on your VPS.
Do the steps in order.
Nothing here is safe to skip if the box is reachable from the public internet.

## Security model in one paragraph

Only Caddy is public (ports 80 and 443).
Every other service binds to `127.0.0.1` inside the VPS, so the only way in
from outside is through a Caddy site block.
The sensitive dashboards (n8n, KeiRouter, hermes) sit behind HTTP basic_auth in
Caddy, layered on top of each service's own login.
CouchDB is reached through Caddy too, but authenticates with its own user and
password because the Obsidian LiveSync plugin needs to send those directly.
Qdrant is never exposed; reach it over an SSH tunnel when you need it.

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
hermes.ghiath.id
n8n.ghiath.id
router.ghiath.id
couch.ghiath.id
```

Wait for propagation (`dig +short n8n.ghiath.id` should return the VPS IP)
before starting Caddy, otherwise Let's Encrypt issuance will fail and rate-limit.

## 3. Clone and configure

```bash
git clone <your-private-repo-url> ghiath
cd ghiath
cp .env.example .env
```

Fill `.env` with production values:

- `ENVIRONMENT=production`
- Strong `KEIROUTER_MASTER_KEY` (`openssl rand -base64 32`)
- Strong `N8N_ENCRYPTION_KEY` (`openssl rand -hex 24`) - keep this stable, it
  decrypts saved n8n credentials
- Strong `COUCHDB_PASSWORD` (`openssl rand -hex 16`)
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

- **n8n**: open `https://n8n.ghiath.id`, get past basic_auth, then immediately
  create the owner account. Until that account exists, do not share the URL.
- **KeiRouter**: open `https://router.ghiath.id`, get past basic_auth, log in
  with the default password `keirouter`, and change it at once. Add your
  provider keys here.
- **hermes**: keep the gateway bound to the host loopback and let Caddy proxy
  it. hermes refuses to serve a public bind without its own auth provider, so
  configure that during `hermes setup`.

## 6. hermes on the VPS

hermes runs on the host, not in Docker. Either install fresh:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
# recreate ippang / kuli / pakprof and their models (see README step 5)
```

or move your existing profiles from your Mac:

```bash
# on the Mac
hermes profile export kuli --output kuli.tar
scp kuli.tar user@vps:~/
# on the VPS
hermes profile import kuli.tar
```

Then start the gateways you want reachable:

```bash
ippang gateway start
kuli gateway start
pakprof gateway start
```

## 7. Point Obsidian LiveSync at the VPS

In the LiveSync plugin on desktop and mobile, set the URI to
`https://couch.ghiath.id`, with the CouchDB user and password from `.env`, and
the same database name you used locally.

## Reaching internal services

Qdrant and anything else on loopback are reached with an SSH tunnel, not a
public URL:

```bash
ssh -L 6333:localhost:6333 user@vps
# then open http://localhost:6333/dashboard on your laptop
```

## Ongoing

- Rotate `BASIC_AUTH_HASH` and the KeiRouter dashboard password periodically.
- Back up `couchdb/`, `n8n/`, and `obsidian-vault/` (or rely on LiveSync
  replication plus a Git remote for the vault).
- `docker compose pull && make deploy` to update images; `N8N_ENCRYPTION_KEY`
  must not change across updates.
