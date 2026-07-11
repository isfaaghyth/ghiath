#!/usr/bin/env bash
#
# hermes.sh - clean up and (re)provision the Ghiath agents on this host.
#
# Idempotent. It deletes and recreates the ippang, kuli, and pakprof profiles,
# points them at KeiRouter, writes each one's role into its SOUL.md, and installs
# a per-profile gateway on its own port. Run it again any time to reset to a
# known-good state.
#
# Usage:
#   ./scripts/hermes.sh [keirouter-virtual-key]
#   KEIROUTER_VIRTUAL_KEY=kr_xxx ./scripts/hermes.sh
#
# The virtual key is optional; without it the profiles are configured but have
# no api_key (set it later with ./scripts/keirouter-connect.sh). Override any
# model or port with the env vars below if they do not match what KeiRouter
# serves, e.g.:  PAKPROF_MODEL=z-ai/glm-4.6 ./scripts/hermes.sh
#
# Set INSTALL_GATEWAYS=0 to configure the profiles but skip installing the
# background gateway services.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Read a single value from a file without sourcing it (values may contain '$').
getenv_file() { grep -E "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }

# --- configuration (override via env) ---------------------------------------
KEIROUTER_BASE_URL="${KEIROUTER_BASE_URL:-http://localhost:20180/v1}"
VKEY="${1:-${KEIROUTER_VIRTUAL_KEY:-}}"
INSTALL_GATEWAYS="${INSTALL_GATEWAYS:-1}"

# Telegram: token comes from the env or the project .env; it is written into the
# front-door profile so that profile's gateway connects the bot. Change which
# agent owns the bot with TELEGRAM_PROFILE.
TELEGRAM_PROFILE="${TELEGRAM_PROFILE:-ippang}"
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-$(getenv_file "$ROOT/.env" TELEGRAM_BOT_TOKEN)}"

IPPANG_MODEL="${IPPANG_MODEL:-deepseek/deepseek-v2-flash}"
KULI_MODEL="${KULI_MODEL:-anthropic/claude-opus-4-8}"
KULI_SUBAGENT_MODEL="${KULI_SUBAGENT_MODEL:-anthropic/claude-sonnet-5}"
PAKPROF_MODEL="${PAKPROF_MODEL:-z-ai/glm-4.6}"

IPPANG_PORT="${IPPANG_PORT:-8642}"
KULI_PORT="${KULI_PORT:-8643}"
PAKPROF_PORT="${PAKPROF_PORT:-8644}"

# --- preflight --------------------------------------------------------------
command -v hermes >/dev/null 2>&1 || {
	echo "hermes is not installed or not on PATH."
	echo "Install it first:"
	echo "  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
	exit 1
}
echo "hermes: $(hermes --version 2>/dev/null | head -1)"

# --- 1. clean up ------------------------------------------------------------
# '</dev/null' guarantees no command blocks on a prompt; '|| true' tolerates
# services or profiles that do not exist yet, so cleanup never aborts.
echo
echo "== cleanup =="
# Remove the default profile's gateway, which otherwise squats port 8642.
hermes gateway uninstall </dev/null >/dev/null 2>&1 || true
for a in ippang kuli pakprof; do
	"$a" gateway uninstall </dev/null >/dev/null 2>&1 || true
	hermes profile delete -y "$a" </dev/null >/dev/null 2>&1 || true
	echo "  reset $a"
done

# --- 2. recreate and configure ----------------------------------------------
echo
echo "== create and configure profiles =="
configure() {
	local name="$1" model="$2"
	hermes profile create "$name" --description "Ghiath ecosystem agent" </dev/null >/dev/null 2>&1
	"$name" config set model.default "$model" >/dev/null
	"$name" config set model.provider custom >/dev/null
	"$name" config set model.base_url "$KEIROUTER_BASE_URL" >/dev/null
	if [ -n "$VKEY" ]; then
		"$name" config set model.api_key "$VKEY" >/dev/null
	fi
	echo "  $name -> $model (provider=custom, base_url=$KEIROUTER_BASE_URL)"
}
configure ippang "$IPPANG_MODEL"
configure kuli "$KULI_MODEL"
kuli config set subagents.model "$KULI_SUBAGENT_MODEL" >/dev/null
echo "  kuli subagents -> $KULI_SUBAGENT_MODEL"
configure pakprof "$PAKPROF_MODEL"

# --- 3. write roles into SOUL.md --------------------------------------------
echo
echo "== write SOUL.md roles =="
soul() { echo "$HOME/.hermes/profiles/$1/SOUL.md"; }

cat >> "$(soul ippang)" <<'EOF'


## Your role in the Ghiath ecosystem

You are ippang, a lightweight personal assistant for fast everyday tasks.
You own the vault folder obsidian-vault/scratchpads/ as your inbox and workspace.
To hand off, write a note into another agent's folder: a research brief into
obsidian-vault/memory/ for pakprof, or a build request into
obsidian-vault/projects/ for kuli. An n8n vault-watch workflow triggers them.
EOF

cat >> "$(soul kuli)" <<'EOF'


## Your role in the Ghiath ecosystem

You are kuli, a software engineer buddy. You plan as an orchestrator with a
strong model and delegate execution to faster subagents.
You own the vault folder obsidian-vault/projects/ as your inbox and workspace.
You usually receive work when pakprof or ippang drops a note into projects/.
If you need more research, write a brief into obsidian-vault/memory/ for pakprof.
EOF

cat >> "$(soul pakprof)" <<'EOF'


## Your role in the Ghiath ecosystem

You are pakprof, a researcher who does deep reading and synthesis.
You own the vault folder obsidian-vault/memory/ as your inbox and workspace.
You usually receive a research brief from ippang in memory/. When findings should
be built into something, drop a task note into obsidian-vault/projects/ for kuli.
EOF
echo "  wrote roles for ippang, kuli, pakprof"

# --- 3b. telegram (optional) ------------------------------------------------
# Write TELEGRAM_BOT_TOKEN into the front-door profile's .env. hermes reads it
# from there and connects the bot automatically when that gateway runs.
echo
if [ -n "$TG_TOKEN" ]; then
	echo "== telegram =="
	penv="$HOME/.hermes/profiles/$TELEGRAM_PROFILE/.env"
	touch "$penv"
	grep -v '^TELEGRAM_BOT_TOKEN=' "$penv" > "$penv.tmp" 2>/dev/null || true
	echo "TELEGRAM_BOT_TOKEN=$TG_TOKEN" >> "$penv.tmp"
	mv "$penv.tmp" "$penv"
	echo "  bot token set on profile '$TELEGRAM_PROFILE'; it connects when that gateway runs"
else
	echo "== telegram: skipped (no TELEGRAM_BOT_TOKEN in env or $ROOT/.env) =="
fi

# --- 4. install per-profile gateways ----------------------------------------
# Each gateway needs its own port; two cannot share 8642. Fully non-interactive
# via flags (no prompts, so it cannot hang). If your hermes build does not honor
# PORT for the installed service, the status check below shows what actually
# bound, and you can set distinct ports per profile another way.
if [ "$INSTALL_GATEWAYS" = "1" ]; then
	echo
	echo "== install gateways =="
	PORT="$IPPANG_PORT"  ippang  gateway install --force --start-now --start-on-login </dev/null >/dev/null 2>&1 || true
	PORT="$KULI_PORT"    kuli    gateway install --force --start-now --start-on-login </dev/null >/dev/null 2>&1 || true
	PORT="$PAKPROF_PORT" pakprof gateway install --force --start-now --start-on-login </dev/null >/dev/null 2>&1 || true
	echo "  requested ippang:$IPPANG_PORT kuli:$KULI_PORT pakprof:$PAKPROF_PORT"
fi

# --- 5. status --------------------------------------------------------------
echo
echo "== status =="
hermes profile list 2>/dev/null | grep -E 'Profile|ippang|kuli|pakprof|default' || true
if [ "$INSTALL_GATEWAYS" = "1" ]; then
	echo "listening gateway ports:"
	if command -v ss >/dev/null 2>&1; then
		ss -ltnp 2>/dev/null | grep -E ":($IPPANG_PORT|$KULI_PORT|$PAKPROF_PORT)\b" || echo "  (none bound - check: ippang gateway status)"
	elif command -v lsof >/dev/null 2>&1; then
		lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | grep -E ":($IPPANG_PORT|$KULI_PORT|$PAKPROF_PORT)\b" || echo "  (none bound - check: ippang gateway status)"
	fi
fi

echo
echo "done."
[ -z "$VKEY" ] && echo "NOTE: no virtual key set. Run ./scripts/keirouter-connect.sh <key> once you mint one in KeiRouter."
echo "Verify a model actually responds:  ippang -z \"hi\""
echo "If that 401s, the model slug or KeiRouter provider key is the issue, not the wiring."
if [ -n "$TG_TOKEN" ]; then
	echo "Telegram: open your bot in Telegram and send it a message; '$TELEGRAM_PROFILE' answers."
	echo "  Lock it down: message the bot once, then set platforms.telegram.allowed_chats"
	echo "  in ~/.hermes/profiles/$TELEGRAM_PROFILE/config.yaml to your own chat id."
fi
