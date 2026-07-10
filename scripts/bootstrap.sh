#!/usr/bin/env bash
#
# Ghiath bootstrap.
# Idempotent one-command bring-up for local dev or the VPS.
#
#   ./scripts/bootstrap.sh          # local stack (no Caddy)
#   ./scripts/bootstrap.sh prod     # production stack (adds Caddy, needs DNS)
#
# It generates real secrets into .env on first run (so services never persist a
# placeholder key), brings the stack up, waits for health, and initializes
# CouchDB for Obsidian LiveSync. Running it again is safe: existing secrets in
# .env are left untouched.

set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-local}"

gen_b64_32() { openssl rand -base64 32; }
gen_hex()    { openssl rand -hex "${1:-24}"; }

# --- 1. .env ----------------------------------------------------------------
if [ ! -f .env ]; then
	echo "[bootstrap] creating .env from .env.example with generated secrets"
	cp .env.example .env
	# Fill the machine secrets; leave provider keys / basic_auth / acme for you.
	sed -i.bak "s|^KEIROUTER_MASTER_KEY=.*|KEIROUTER_MASTER_KEY=$(gen_b64_32)|" .env
	sed -i.bak "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$(gen_hex 24)|" .env
	sed -i.bak "s|^COUCHDB_PASSWORD=.*|COUCHDB_PASSWORD=$(gen_hex 16)|" .env
	rm -f .env.bak
	echo "[bootstrap] .env created. Add provider keys in KeiRouter later; for"
	echo "            prod also set ACME_EMAIL, BASIC_AUTH_HASH, and N8N_* URLs."
else
	echo "[bootstrap] .env already exists, leaving it untouched"
fi

# --- 2. prepare bind-mount data dirs ----------------------------------------
# Create these before `up` so they are owned by the invoking user, not root.
# n8n and keirouter run as non-root and cannot write into a root-owned dir
# (Docker Desktop hides this on macOS; a real Linux host does not). On the
# typical Ubuntu VPS the login user is uid 1000, which is what these images use.
mkdir -p n8n keirouter couchdb qdrant

# --- 3. bring up ------------------------------------------------------------
if [ "$MODE" = "prod" ]; then
	echo "[bootstrap] starting stack in PROD mode (with Caddy)"
	docker compose --profile prod up -d --build
else
	echo "[bootstrap] starting stack in LOCAL mode"
	docker compose up -d --build
fi

# --- 4. wait for health -----------------------------------------------------
echo "[bootstrap] waiting for services to answer..."
wait_http() {
	local name="$1" url="$2" tries=60 code
	while true; do
		# Any HTTP response means the service is up. CouchDB returns 401 once
		# require_valid_user is enabled, which is healthy - only a refused
		# connection yields 000.
		code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
		[ "$code" != "000" ] && { echo "[bootstrap] $name is up ($code)"; break; }
		tries=$((tries - 1))
		[ "$tries" -le 0 ] && { echo "[bootstrap] TIMEOUT waiting for $name ($url)"; return 1; }
		sleep 2
	done
}
wait_http "qdrant"    "http://localhost:6333/healthz"
wait_http "couchdb"   "http://localhost:5984/"
wait_http "keirouter" "http://localhost:20180/"
wait_http "n8n"       "http://localhost:5678/"

# --- 5. couchdb init for LiveSync ------------------------------------------
echo "[bootstrap] initializing CouchDB for Obsidian LiveSync"
./scripts/couch-init.sh

echo
echo "[bootstrap] done."
echo "  n8n:        http://localhost:5678   (create the owner account now)"
echo "  KeiRouter:  http://localhost:20180  (default password 'keirouter' - change it)"
echo "  Qdrant:     http://localhost:6333/dashboard"
echo "  CouchDB:    http://localhost:5984/_utils"
echo
echo "  Next: run 'make test' to smoke-test, and set up hermes profiles"
echo "  on the host (see README)."
