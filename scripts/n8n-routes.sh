#!/usr/bin/env bash
#
# n8n-routes.sh - derive GHIATH_ROUTES from agents.conf.
#
# Both n8n workflows (router.json, vault-watch.json) read a GHIATH_ROUTES env
# var: a JSON map of agent -> {port, model, folder, match?, default?}. Keeping it
# generated from agents.conf means the workflow JSON in the repo stays neutral
# (no personal agent names) and can never drift from the real agent setup.
#
#   ./scripts/n8n-routes.sh            # print the GHIATH_ROUTES=... env line
#   ./scripts/n8n-routes.sh --json     # print just the JSON value
#
# Wire it up once:
#   ./scripts/n8n-routes.sh >> .env && docker compose up -d n8n
#
# The home-side agent is deliberately absent: it is isolated, has no vault
# handoffs, and n8n never routes to it.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [ -f "$ROOT/agents.conf" ]; then
	# shellcheck disable=SC1091
	source "$ROOT/agents.conf"
elif [ -f "$ROOT/agents.conf.example" ]; then
	# shellcheck disable=SC1091
	source "$ROOT/agents.conf.example"
else
	echo "no agents.conf found" >&2
	exit 1
fi

ASSISTANT_NAME="${ASSISTANT_NAME:-assistant}"
ASSISTANT_MODEL="${ASSISTANT_MODEL:-deepseek/deepseek-v2-flash}"
ASSISTANT_FOLDER="${ASSISTANT_FOLDER:-scratchpads}"
ASSISTANT_PORT="${ASSISTANT_PORT:-8642}"

ENGINEER_NAME="${ENGINEER_NAME:-engineer}"
ENGINEER_MODEL="${ENGINEER_MODEL:-anthropic/claude-opus-4-8}"
ENGINEER_FOLDER="${ENGINEER_FOLDER:-projects}"
ENGINEER_PORT="${ENGINEER_PORT:-8643}"

RESEARCHER_NAME="${RESEARCHER_NAME:-researcher}"
RESEARCHER_MODEL="${RESEARCHER_MODEL:-z-ai/glm-4.6}"
RESEARCHER_FOLDER="${RESEARCHER_FOLDER:-memory}"
RESEARCHER_PORT="${RESEARCHER_PORT:-8644}"

# Keyword triage, used only by router.json's webhook front door. The assistant is
# the fallback, so it needs no match. Keep these ASCII and pipe-separated.
ENGINEER_MATCH="${ENGINEER_MATCH:-build|code|ngoding|implement|refactor|debug|bug|deploy}"
RESEARCHER_MATCH="${RESEARCHER_MATCH:-research|cari|riset|investigate|find out|literature}"

# One line, no spaces after separators: this value is consumed from .env, where a
# trailing newline or stray quoting would corrupt it.
JSON=$(printf '{"%s":{"port":%s,"model":"%s","folder":"%s","default":true},"%s":{"port":%s,"model":"%s","folder":"%s","match":"%s"},"%s":{"port":%s,"model":"%s","folder":"%s","match":"%s"}}' \
	"$ASSISTANT_NAME" "$ASSISTANT_PORT" "$ASSISTANT_MODEL" "$ASSISTANT_FOLDER" \
	"$ENGINEER_NAME" "$ENGINEER_PORT" "$ENGINEER_MODEL" "$ENGINEER_FOLDER" "$ENGINEER_MATCH" \
	"$RESEARCHER_NAME" "$RESEARCHER_PORT" "$RESEARCHER_MODEL" "$RESEARCHER_FOLDER" "$RESEARCHER_MATCH")

if [ "${1:-}" = "--json" ]; then
	printf '%s\n' "$JSON"
else
	printf 'GHIATH_ROUTES=%s\n' "$JSON"
fi
