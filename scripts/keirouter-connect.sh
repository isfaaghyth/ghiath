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

VKEY="${1:-}"
if [ -z "$VKEY" ]; then
	echo "usage: $0 <keirouter-virtual-key>" >&2
	exit 1
fi

command -v hermes >/dev/null 2>&1 || { echo "hermes not on PATH" >&2; exit 1; }

for p in ippang kuli pakprof; do
	hermes profile show "$p" >/dev/null 2>&1 || { echo "skip $p (no such profile)"; continue; }
	"$p" config set model.base_url http://localhost:20180/v1 >/dev/null
	"$p" config set model.provider custom >/dev/null
	"$p" config set model.api_key "$VKEY" >/dev/null
	echo "connected $p -> KeiRouter"
done

echo
echo "Done. Test one:  ippang -z 'say hello in 3 words'"
echo "If it 401s, the virtual key is wrong. If it errors upstream, add the"
echo "provider key for that model inside the KeiRouter dashboard."
