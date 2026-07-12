#!/usr/bin/env bash
#
# force-reinstall.sh - tear down and re-provision Ghiath on this host.
#
# Interactively pick how destructive the reset should be, then it rebuilds the
# Docker stack and re-provisions the host-side hermes agents. Meant for pushing
# a fresh version of the repo onto a server after `git pull`.
#
#   ./scripts/force-reinstall.sh [keirouter-virtual-key]
#
# The virtual key is passed through to hermes.sh so the agents reconnect to
# KeiRouter. Without it, agents are recreated but left without an api_key (set
# it later with ./scripts/keirouter-connect.sh).
#
# Flags / env:
#   --yes            skip the final confirmation prompt (for automation)
#   LEVEL=1|2|3      preselect the destructive level, skipping the menu:
#                      1 = rebuild containers, keep all data
#                      2 = rebuild + wipe indexes (qdrant) and caddy certs
#                      3 = nuke everything (all bind mounts + volumes)
#   SKIP_AGENTS=1    do not reprovision hermes profiles (Docker only)
#   MODE=local|prod  compose mode (default: prod)

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VKEY="${1:-}"
AUTO_YES=0
[ "${1:-}" = "--yes" ] && { AUTO_YES=1; VKEY=""; }
[ "${2:-}" = "--yes" ] && AUTO_YES=1
MODE="${MODE:-prod}"
SKIP_AGENTS="${SKIP_AGENTS:-0}"

# Load configured vault folder names so we wipe/rename the right directories.
if [ -f "$ROOT/agents.conf" ]; then
	# shellcheck disable=SC1091
	source "$ROOT/agents.conf"
elif [ -f "$ROOT/agents.conf.example" ]; then
	# shellcheck disable=SC1091
	source "$ROOT/agents.conf.example"
fi
PRIMARY_VAULT="${PRIMARY_VAULT:-vault}"
HOME_VAULT="${HOME_VAULT:-vault-home}"
ENABLE_HOME="${ENABLE_HOME:-0}"

compose() { # run docker compose with the right profiles for the chosen mode
	local profiles=()
	[ "$MODE" = "prod" ] && profiles+=(--profile prod)
	# Without this the home-side indexer stays down while hermes.sh still creates
	# the home agent, leaving its vault silently unindexed.
	[ "$ENABLE_HOME" = "1" ] && profiles+=(--profile home)
	docker compose "${profiles[@]+"${profiles[@]}"}" "$@"
}

# --- choose destructive level -----------------------------------------------
LEVEL="${LEVEL:-}"
if [ -z "$LEVEL" ]; then
	echo "How much should be reset?"
	echo
	echo "  1) Rebuild containers, KEEP all data"
	echo "       Rebuilds images and recreates every container. Your CouchDB"
	echo "       (LiveSync), n8n workflows/credentials, Qdrant index, and vault"
	echo "       stay on disk. Safe re-provision."
	echo
	echo "  2) Rebuild + wipe INDEXES"
	echo "       Everything in (1), plus delete the Qdrant embeddings ($ROOT/qdrant)"
	echo "       and the Caddy TLS cert volumes. CouchDB and n8n are kept. The"
	echo "       index rebuilds automatically from the vault. No note data lost."
	echo
	echo "  3) NUKE EVERYTHING"
	echo "       Delete ALL bind-mount data (couchdb, n8n, qdrant, keirouter) and"
	echo "       all volumes, then regenerate from scratch. You lose LiveSync"
	echo "       server data, n8n workflows/credentials, and KeiRouter keys, and"
	echo "       must re-import/re-key afterwards. Vault notes on disk are kept"
	echo "       unless you also delete the vault folder yourself."
	echo
	printf "Enter 1, 2, or 3 (or q to abort): "
	read -r LEVEL
fi
case "$LEVEL" in
	1|2|3) ;;
	q|Q) echo "aborted."; exit 0 ;;
	*) echo "invalid choice: $LEVEL" >&2; exit 1 ;;
esac

# --- describe and confirm ---------------------------------------------------
echo
echo "Plan (MODE=$MODE, level=$LEVEL):"
echo "  - docker compose down (removes containers)"
[ "$LEVEL" = "1" ] && echo "  - keep all data"
[ "$LEVEL" = "2" ] && echo "  - remove volumes + delete $ROOT/qdrant"
[ "$LEVEL" = "3" ] && echo "  - remove volumes + delete $ROOT/{couchdb,n8n,qdrant,keirouter}"
echo "  - rebuild images and recreate all containers"
echo "  - reinitialize CouchDB for LiveSync"
[ "$SKIP_AGENTS" = "0" ] && echo "  - reprovision hermes agents (host)"
echo

if [ "$AUTO_YES" != "1" ] && [ "$LEVEL" != "1" ]; then
	printf "This is destructive. Type 'yes' to proceed: "
	read -r ans
	[ "$ans" = "yes" ] || { echo "aborted."; exit 0; }
fi

# --- tear down --------------------------------------------------------------
echo
echo "== tearing down =="
if [ "$LEVEL" = "1" ]; then
	compose down || true
else
	# -v also removes the named volumes (caddy_data, caddy_config).
	compose down -v || true
fi

if [ "$LEVEL" = "2" ]; then
	echo "  deleting $ROOT/qdrant"
	rm -rf "$ROOT/qdrant"
fi
if [ "$LEVEL" = "3" ]; then
	for d in couchdb n8n qdrant keirouter; do
		echo "  deleting $ROOT/$d"
		rm -rf "${ROOT:?}/$d"
	done
fi

# --- rebuild ----------------------------------------------------------------
# Recreate bind-mount dirs so they are owned by the invoking user, not root.
mkdir -p n8n keirouter couchdb qdrant

echo
echo "== rebuilding stack =="
compose up -d --build --force-recreate

# --- wait for health --------------------------------------------------------
echo
echo "== waiting for services =="
wait_http() {
	local name="$1" url="$2" tries=60 code
	while true; do
		code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
		[ "$code" != "000" ] && { echo "  $name up ($code)"; break; }
		tries=$((tries - 1))
		[ "$tries" -le 0 ] && { echo "  TIMEOUT waiting for $name ($url)"; return 1; }
		sleep 2
	done
}
wait_http "qdrant"    "http://localhost:6333/healthz"
wait_http "couchdb"   "http://localhost:5984/"
wait_http "keirouter" "http://localhost:20180/"
wait_http "n8n"       "http://localhost:5678/"

# --- couchdb init -----------------------------------------------------------
echo
echo "== couchdb init for LiveSync =="
./scripts/couch-init.sh

# --- reprovision host agents ------------------------------------------------
if [ "$SKIP_AGENTS" = "0" ]; then
	echo
	echo "== reprovision hermes agents =="
	if command -v hermes >/dev/null 2>&1; then
		if [ -n "$VKEY" ]; then
			./scripts/hermes.sh "$VKEY"
		else
			./scripts/hermes.sh
		fi
	else
		echo "  hermes not on PATH; skipping agent reprovision."
		echo "  install hermes, then run ./scripts/hermes.sh <keirouter-key>"
	fi
fi

echo
echo "== done =="
echo "Smoke-test:  make test"
if [ "$LEVEL" = "3" ]; then
	echo "Level 3 was destructive. Remember to:"
	echo "  - re-import n8n workflows (n8n-workflows/*.json) via the n8n UI"
	echo "  - re-add provider keys / mint a virtual key in KeiRouter"
fi
echo "If you changed the workflow JSON, re-import router.json + vault-watch.json in n8n."
