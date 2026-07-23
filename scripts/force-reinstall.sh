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
# KeiRouter. Without it, the agents keep whatever key they already had.
#
# The Docker levels below only ever touch Docker state. The host-side agents are
# re-provisioned by hermes.sh, which is non-destructive: profiles, sessions,
# memories and Telegram bindings survive every level, including 3.
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
WORK_VAULT="${WORK_VAULT:-vault-work}"
HOME_VAULT="${HOME_VAULT:-vault-home}"

compose() { # run docker compose with the right profiles for the chosen mode
	local profiles=()
	[ "$MODE" = "prod" ] && profiles+=(--profile prod)
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
# The vaults belong here too: if compose mounts a vault that does not exist yet,
# the docker daemon creates it as root, and the host-side hermes.sh then cannot
# write the agent folders into it ("mkdir: Permission denied").
# Both vaults: livesync-bridge and the two indexers mount them, and a mount
# target docker has to invent becomes root-owned.
mkdir -p n8n keirouter couchdb qdrant "$WORK_VAULT" "$HOME_VAULT"

# Keep .env and livesync-bridge/config.json in step with agents.conf before
# compose interpolates them. Without this a renamed vault silently mounts the
# old (empty) folder.
./scripts/sync-env.sh --write

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
# /_up (not /) - CouchDB answers / while still initializing a fresh data dir.
wait_http "couchdb"   "http://localhost:5984/_up"
wait_http "keirouter" "http://localhost:20180/"
# n8n is an opt-in add-on ("addon" profile) and is not expected to be running.

# --- couchdb init -----------------------------------------------------------
echo
echo "== couchdb init for LiveSync =="
./scripts/couch-init.sh

# --- reprovision host agents ------------------------------------------------
if [ "$SKIP_AGENTS" = "0" ]; then
	echo
	echo "== reprovision hermes agents (non-destructive) =="
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
	echo "Level 3 was destructive. Remember to re-add provider keys and mint a"
	echo "virtual key in KeiRouter, then: ./scripts/keirouter-connect.sh <kr_key>"
fi
