#!/usr/bin/env bash
#
# Connect the hermes profiles to KeiRouter.
# Sets the KeiRouter API key (kr_...) as each profile's model api_key, so the
# agents authenticate to KeiRouter (which holds the real upstream provider keys).
#
# Usage:
#   ./scripts/keirouter-connect.sh <kr_key>
#
# Mint the kr_ key (this is NOT the .env master key):
#   docker compose exec keirouter keirouter bootstrap -key-name ghiath-agents
# Also add an upstream provider key (Anthropic and/or OpenRouter) in the
# KeiRouter dashboard so it can reach a model. Log in with the default password
# 'keirouter' and change it first.
#
# The provider and base_url are already set by the project setup; this only
# fills in the key.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VKEY="${1:-}"
if [ -z "$VKEY" ]; then
	echo "usage: $0 <keirouter-virtual-key>" >&2
	exit 1
fi

command -v hermes >/dev/null 2>&1 || { echo "hermes not on PATH" >&2; exit 1; }

# Load the configured agent names (falls back to the shipped defaults).
if [ -f "$ROOT/agents.conf" ]; then source "$ROOT/agents.conf"; elif [ -f "$ROOT/agents.conf.example" ]; then source "$ROOT/agents.conf.example"; fi
ASSISTANT_NAME="${ASSISTANT_NAME:-assistant}"
ENGINEER_NAME="${ENGINEER_NAME:-engineer}"
RESEARCHER_NAME="${RESEARCHER_NAME:-researcher}"
PROFILES="$ASSISTANT_NAME $ENGINEER_NAME $RESEARCHER_NAME"
[ "${ENABLE_HOME:-0}" = "1" ] && PROFILES="$PROFILES ${HOME_NAME:-home}"

for p in $PROFILES; do
	hermes profile show "$p" >/dev/null 2>&1 || { echo "skip $p (no such profile)"; continue; }
	"$p" config set model.base_url http://localhost:20180/v1 >/dev/null
	"$p" config set model.provider custom >/dev/null
	"$p" config set model.api_key "$VKEY" >/dev/null
	echo "connected $p -> KeiRouter"
done

echo
echo "Done. Test one:  $ASSISTANT_NAME -z 'say hello in 3 words'"
echo "If it 401s, the virtual key is wrong. If it errors upstream, add the"
echo "provider key for that model inside the KeiRouter dashboard."
