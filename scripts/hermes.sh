#!/usr/bin/env bash
#
# hermes.sh - clean up and (re)provision the Ghiath agents on this host.
#
# Idempotent. It deletes and recreates the configured profiles, points them at
# KeiRouter, writes each one's role into its SOUL.md, seeds the vault, and
# installs a per-profile gateway on its own port. Run it again any time to reset
# to a known-good state.
#
# WARNING: this is DESTRUCTIVE. It runs `hermes profile delete` on every
# configured agent and reinstalls their gateways, so every live Telegram/Discord
# binding drops and reconnects. Do NOT run it just to copy files. Two things are
# easy to lose:
#   - nyai (the home/family bot) is only provisioned with ENABLE_HOME=1. Without
#     that flag this script does not touch nyai, so a churn can leave it dark.
#   - pass your KeiRouter virtual key, or the recreated agents have no api_key
#     and answer nothing (401).
# To restore everything after an accidental run:
#   ENABLE_HOME=1 ./scripts/hermes.sh <keirouter-virtual-key>
#
# All names, models, vault folders, and ports are configuration, not hardcoded.
# Copy agents.conf.example to agents.conf and edit it:
#
#   cp agents.conf.example agents.conf
#   ./scripts/hermes.sh [keirouter-virtual-key]
#
# The virtual key is optional; without it the profiles are configured but have
# no api_key (set it later with ./scripts/keirouter-connect.sh). Any value in
# agents.conf can also be overridden inline, e.g.:
#   RESEARCHER_MODEL=z-ai/glm-4.6 ./scripts/hermes.sh
#
# Set INSTALL_GATEWAYS=0 to configure the profiles but skip installing the
# background gateway services. Set ENABLE_HOME=1 to also provision the isolated
# "home" assistant.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Read a single value from a file without sourcing it (values may contain '$').
getenv_file() { grep -E "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }

# --- load configuration -----------------------------------------------------
# agents.conf holds the (possibly personalized) config; agents.conf.example is
# the neutral shipped default. Prefer the former, fall back to the latter so a
# fresh clone runs out of the box. Inline env vars still win over both.
if [ -f "$ROOT/agents.conf" ]; then
	# shellcheck disable=SC1091
	source "$ROOT/agents.conf"
	echo "config: agents.conf"
elif [ -f "$ROOT/agents.conf.example" ]; then
	# shellcheck disable=SC1091
	source "$ROOT/agents.conf.example"
	echo "config: agents.conf.example (defaults; copy it to agents.conf to customize)"
fi

KEIROUTER_BASE_URL="${KEIROUTER_BASE_URL:-http://localhost:20180/v1}"
VKEY="${1:-${KEIROUTER_VIRTUAL_KEY:-}}"
INSTALL_GATEWAYS="${INSTALL_GATEWAYS:-1}"

# Primary side (defaults mirror agents.conf.example so the script is safe even
# with no config file present).
ASSISTANT_NAME="${ASSISTANT_NAME:-assistant}"
ASSISTANT_MODEL="${ASSISTANT_MODEL:-deepseek/deepseek-v2-flash}"
ASSISTANT_FOLDER="${ASSISTANT_FOLDER:-scratchpads}"
ASSISTANT_PORT="${ASSISTANT_PORT:-8642}"

ENGINEER_NAME="${ENGINEER_NAME:-engineer}"
ENGINEER_MODEL="${ENGINEER_MODEL:-anthropic/claude-opus-4-8}"
ENGINEER_SUBAGENT_MODEL="${ENGINEER_SUBAGENT_MODEL:-anthropic/claude-sonnet-5}"
ENGINEER_FOLDER="${ENGINEER_FOLDER:-projects}"
ENGINEER_PORT="${ENGINEER_PORT:-8643}"

RESEARCHER_NAME="${RESEARCHER_NAME:-researcher}"
RESEARCHER_MODEL="${RESEARCHER_MODEL:-z-ai/glm-4.6}"
RESEARCHER_FOLDER="${RESEARCHER_FOLDER:-memory}"
RESEARCHER_PORT="${RESEARCHER_PORT:-8644}"

PRIMARY_VAULT="${PRIMARY_VAULT:-vault}"
PRIMARY_TELEGRAM_AGENT="${PRIMARY_TELEGRAM_AGENT:-$ASSISTANT_NAME}"

# Home side (optional, isolated).
ENABLE_HOME="${ENABLE_HOME:-0}"
HOME_NAME="${HOME_NAME:-home}"
HOME_MODEL="${HOME_MODEL:-deepseek/deepseek-v2-flash}"
HOME_PORT="${HOME_PORT:-8645}"
HOME_VAULT="${HOME_VAULT:-vault-home}"

# Telegram tokens come from .env (secrets), never from agents.conf.
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-$(getenv_file "$ROOT/.env" TELEGRAM_BOT_TOKEN)}"
HOME_TG_TOKEN="${HOME_TELEGRAM_BOT_TOKEN:-$(getenv_file "$ROOT/.env" HOME_TELEGRAM_BOT_TOKEN)}"

# --- preflight --------------------------------------------------------------
command -v hermes >/dev/null 2>&1 || {
	echo "hermes is not installed or not on PATH."
	echo "Install it first:"
	echo "  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
	exit 1
}
echo "hermes: $(hermes --version 2>/dev/null | head -1)"

PRIMARY_AGENTS="$ASSISTANT_NAME $ENGINEER_NAME $RESEARCHER_NAME"
ALL_AGENTS="$PRIMARY_AGENTS"
[ "$ENABLE_HOME" = "1" ] && ALL_AGENTS="$ALL_AGENTS $HOME_NAME"
PRIMARY_PORTS="$ASSISTANT_PORT $ENGINEER_PORT $RESEARCHER_PORT"

# --- 1. clean up ------------------------------------------------------------
# '</dev/null' guarantees no command blocks on a prompt; '|| true' tolerates
# services or profiles that do not exist yet, so cleanup never aborts.
echo
echo "== cleanup =="
# Remove the default profile's gateway, which otherwise squats the base port.
hermes gateway uninstall </dev/null >/dev/null 2>&1 || true
for a in $ALL_AGENTS; do
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
configure "$ASSISTANT_NAME" "$ASSISTANT_MODEL"
configure "$ENGINEER_NAME" "$ENGINEER_MODEL"
"$ENGINEER_NAME" config set subagents.model "$ENGINEER_SUBAGENT_MODEL" >/dev/null
echo "  $ENGINEER_NAME subagents -> $ENGINEER_SUBAGENT_MODEL"
configure "$RESEARCHER_NAME" "$RESEARCHER_MODEL"
[ "$ENABLE_HOME" = "1" ] && configure "$HOME_NAME" "$HOME_MODEL"

# --- 3. write roles into SOUL.md --------------------------------------------
echo
echo "== write SOUL.md roles =="
soul() { echo "$HOME/.hermes/profiles/$1/SOUL.md"; }

# Shared note conventions appended to every primary-side profile. Every note an
# agent writes MUST start with this YAML front-matter. It powers the Obsidian
# Bases views AND makes handoffs loop-safe: the vault-watch workflow only acts
# on notes whose status is "open", so an agent writing its own result (status
# "done", or type "result") never re-triggers itself.
# Note the backticks are escaped because this heredoc is expanded.
note_conventions() {
	cat <<EOF


## Note format (required)

Every Markdown note you create in the vault MUST begin with this YAML
front-matter, then the body:

\`\`\`
---
type: task        # task | brief | result | note
status: open      # open | doing | done  (only "open" triggers an agent)
owner: <agent>    # the agent who should act next (you, when it is a result)
from: <agent>     # who created this note
created: YYYY-MM-DD
tags: []
---
\`\`\`

Rules:
- A handoff is an "open" note placed in the target agent's folder, with
  "owner" set to that agent.
- When you finish work, write your output as type "result" with status
  "done" and owner set to yourself. Never leave your own output "open", or
  you will re-trigger yourself.
- If you pick up an "open" note, set its status to "doing" while working and
  "done" when finished.
EOF
}

# Absolute paths. A gateway runs as a background service, so its working directory
# is not the repo: a relative "vault/projects/" would resolve somewhere the n8n
# vault-watch workflow is not watching, and the handoff would vanish silently.
VAULT_ABS="$ROOT/$PRIMARY_VAULT"
HOME_VAULT_ABS="$ROOT/$HOME_VAULT"

cat >> "$(soul "$ASSISTANT_NAME")" <<EOF


## Your role in the Ghiath ecosystem

You are $ASSISTANT_NAME, a lightweight personal assistant for fast everyday tasks.
You own the vault folder $VAULT_ABS/$ASSISTANT_FOLDER/ as your inbox and workspace.
To hand off, write an "open" note into another agent's folder: a research brief
into $VAULT_ABS/$RESEARCHER_FOLDER/ for $RESEARCHER_NAME, or a build request into
$VAULT_ABS/$ENGINEER_FOLDER/ for $ENGINEER_NAME. An n8n vault-watch workflow triggers them.
Always write vault notes to these absolute paths, never to a relative path.
EOF
note_conventions >> "$(soul "$ASSISTANT_NAME")"

cat >> "$(soul "$ENGINEER_NAME")" <<EOF


## Your role in the Ghiath ecosystem

You are $ENGINEER_NAME, a software engineer buddy. You plan as an orchestrator with a
strong model and delegate execution to faster subagents.
You own the vault folder $VAULT_ABS/$ENGINEER_FOLDER/ as your inbox and workspace.
You usually receive work when $RESEARCHER_NAME or $ASSISTANT_NAME drops an "open" note into
$VAULT_ABS/$ENGINEER_FOLDER/. If you need more research, write a brief into
$VAULT_ABS/$RESEARCHER_FOLDER/ for $RESEARCHER_NAME.
Always write vault notes to these absolute paths, never to a relative path.
EOF
note_conventions >> "$(soul "$ENGINEER_NAME")"

cat >> "$(soul "$RESEARCHER_NAME")" <<EOF


## Your role in the Ghiath ecosystem

You are $RESEARCHER_NAME, a researcher who does deep reading and synthesis.
You own the vault folder $VAULT_ABS/$RESEARCHER_FOLDER/ as your inbox and workspace.
You usually receive a research brief from $ASSISTANT_NAME in $VAULT_ABS/$RESEARCHER_FOLDER/.
When findings should be built into something, drop an "open" task note into
$VAULT_ABS/$ENGINEER_FOLDER/ for $ENGINEER_NAME.
Always write vault notes to these absolute paths, never to a relative path.
EOF
note_conventions >> "$(soul "$RESEARCHER_NAME")"
echo "  wrote roles + note conventions for $PRIMARY_AGENTS"

# --- 3b. seed repo skills into each primary profile -------------------------
# hermes recreates profiles from scratch on every run, which wipes any skill
# placed by hand. Custom skills are copied back in here so they persist. Two
# sources, both seeded into each primary profile's skills/custom:
#   skills/        shared skills, tracked in git (e.g. reminders)
#   skills-local/  PRIVATE skills, gitignored - personal/proprietary content
#                  that must never be pushed (see README "Private data & skills")
# Primary agents only: the reminder-scheduler workflow watches the primary vault
# (/data/vault), so a reminder from the isolated home agent would never fire.
for src in skills skills-local; do
	[ -d "$ROOT/$src" ] || continue
	echo
	echo "== seed $src =="
	for a in $PRIMARY_AGENTS; do
		dest="$HOME/.hermes/profiles/$a/skills/custom"
		mkdir -p "$dest"
		cp -R "$ROOT/$src/." "$dest/"
		echo "  seeded $(cd "$ROOT/$src" && ls -d */ 2>/dev/null | tr -d / | tr '\n' ' ')-> $a"
	done
done

# --- 3c. seed hermes cron scripts -------------------------------------------
# `hermes cron --script <name>` resolves names under ~/.hermes/scripts/. Copy the
# repo's tick scripts there so `hermes cron create ... --script reminder-tick.py`
# works. These drive reminders + vault handoffs WITHOUT n8n (see REMINDERS.md).
if [ -d "$ROOT/scripts/hermes-cron" ]; then
	echo
	echo "== seed hermes cron scripts =="
	mkdir -p "$HOME/.hermes/scripts"
	cp "$ROOT"/scripts/hermes-cron/*.py "$HOME/.hermes/scripts/" 2>/dev/null && \
		echo "  seeded $(ls "$ROOT"/scripts/hermes-cron/*.py | xargs -n1 basename | tr '\n' ' ')-> ~/.hermes/scripts/"
fi

if [ "$ENABLE_HOME" = "1" ]; then
	cat >> "$(soul "$HOME_NAME")" <<EOF


## Your role

You are $HOME_NAME, a warm, patient personal assistant for everyday life: reminders,
lists, quick questions, planning, journaling. Keep answers simple and friendly.

You work only within your own vault, $HOME_VAULT_ABS/. You do not know about
or interact with any other agents or vaults. There are no handoffs: everything
you do stays in your vault. Always write notes to that absolute path, never to a
relative path. When you save a note, begin it with YAML
front-matter (type: note, status: done, owner: $HOME_NAME, from: $HOME_NAME, created:
today's date, tags: []).
EOF
	echo "  wrote role for $HOME_NAME (isolated, no handoffs)"
fi

# --- 3a. seed the vault (dashboard + Bases views) ---------------------------
# The vault is created at runtime and gitignored, so seed the observability
# scaffolding here. Idempotent: existing files are never overwritten.
echo
echo "== seed vault dashboard + bases =="
VAULT="$ROOT/$PRIMARY_VAULT"
mkdir -p "$VAULT/$ASSISTANT_FOLDER" "$VAULT/$ENGINEER_FOLDER" "$VAULT/$RESEARCHER_FOLDER"

seed() { # seed <path> ; reads content from stdin, skips if the file exists
	if [ -e "$1" ]; then
		echo "  keep   ${1#$ROOT/}"
	else
		cat > "$1"
		echo "  create ${1#$ROOT/}"
	fi
}

seed "$VAULT/000-Dashboard.md" <<'EOF'
---
type: note
status: done
owner: you
from: you
created: 2025-01-01
tags: [dashboard]
---

# Ghiath Dashboard

Quick capture and a window into what the agents are doing. The live views live
in the Bases below; this note is just a landing pad.

## Quick capture

- 

## Open tasks

![[tasks.base]]

## Recent activity

![[activity.base]]
EOF

# Bases file: every open/doing task across the agent folders.
seed "$VAULT/tasks.base" <<'EOF'
filters:
  and:
    - file.ext == "md"
    - status != "done"
    - type == "task"
views:
  - type: table
    name: Open tasks
    order:
      - file.name
      - status
      - owner
      - from
      - created
    sort:
      - property: created
        direction: DESC
EOF

# Bases file: everything the agents have touched, newest first.
seed "$VAULT/activity.base" <<'EOF'
filters:
  and:
    - file.ext == "md"
    - type != "note"
views:
  - type: table
    name: Recent activity
    order:
      - file.name
      - type
      - status
      - owner
      - created
    sort:
      - property: created
        direction: DESC
EOF

# Seed the home vault with a simple dashboard (no cross-references).
if [ "$ENABLE_HOME" = "1" ]; then
	HVAULT="$ROOT/$HOME_VAULT"
	mkdir -p "$HVAULT"
	seed "$HVAULT/000-Dashboard.md" <<EOF
---
type: note
status: done
owner: $HOME_NAME
from: $HOME_NAME
created: 2025-01-01
tags: [dashboard]
---

# Dashboard

Quick capture and a window into recent notes.

## Quick capture

- 

## Recent notes

![[notes.base]]
EOF
	seed "$HVAULT/notes.base" <<'EOF'
filters:
  and:
    - file.ext == "md"
    - file.name != "000-Dashboard"
views:
  - type: table
    name: Recent notes
    order:
      - file.name
      - type
      - created
    sort:
      - property: created
        direction: DESC
EOF
fi

# --- 3b. telegram (optional) ------------------------------------------------
# Write a bot token into a profile's .env. hermes reads it from there and
# connects the bot automatically when that profile's gateway runs.
echo
set_tg_token() { # set_tg_token <profile> <token>
	local penv="$HOME/.hermes/profiles/$1/.env"
	touch "$penv"
	grep -v '^TELEGRAM_BOT_TOKEN=' "$penv" > "$penv.tmp" 2>/dev/null || true
	echo "TELEGRAM_BOT_TOKEN=$2" >> "$penv.tmp"
	mv "$penv.tmp" "$penv"
	echo "  bot token set on profile '$1'; it connects when that gateway runs"
}
if [ -n "$TG_TOKEN" ]; then
	echo "== telegram =="
	set_tg_token "$PRIMARY_TELEGRAM_AGENT" "$TG_TOKEN"
else
	echo "== telegram: skipped (no TELEGRAM_BOT_TOKEN in env or $ROOT/.env) =="
fi
if [ "$ENABLE_HOME" = "1" ]; then
	if [ -n "$HOME_TG_TOKEN" ]; then
		set_tg_token "$HOME_NAME" "$HOME_TG_TOKEN"
	else
		echo "  $HOME_NAME: no HOME_TELEGRAM_BOT_TOKEN set; its bot stays disconnected until you add one"
	fi
fi

# --- 4. install per-profile gateways ----------------------------------------
# Each gateway needs its own port; two cannot share one. Fully non-interactive
# via flags (no prompts, so it cannot hang). If your hermes build does not honor
# PORT for the installed service, the status check below shows what actually
# bound, and you can set distinct ports per profile another way.
if [ "$INSTALL_GATEWAYS" = "1" ]; then
	echo
	echo "== install gateways =="
	PORT="$ASSISTANT_PORT"  "$ASSISTANT_NAME"  gateway install --force --start-now --start-on-login </dev/null >/dev/null 2>&1 || true
	PORT="$ENGINEER_PORT"   "$ENGINEER_NAME"   gateway install --force --start-now --start-on-login </dev/null >/dev/null 2>&1 || true
	PORT="$RESEARCHER_PORT" "$RESEARCHER_NAME" gateway install --force --start-now --start-on-login </dev/null >/dev/null 2>&1 || true
	echo "  requested $ASSISTANT_NAME:$ASSISTANT_PORT $ENGINEER_NAME:$ENGINEER_PORT $RESEARCHER_NAME:$RESEARCHER_PORT"
	if [ "$ENABLE_HOME" = "1" ]; then
		PORT="$HOME_PORT" "$HOME_NAME" gateway install --force --start-now --start-on-login </dev/null >/dev/null 2>&1 || true
		echo "  requested $HOME_NAME:$HOME_PORT"
	fi
fi

# --- 5. status --------------------------------------------------------------
echo
echo "== status =="
# Build a regex of all configured profile names for the listing grep.
name_re="$(echo "$ALL_AGENTS default" | tr ' ' '|')"
hermes profile list 2>/dev/null | grep -E "Profile|$name_re" || true
if [ "$INSTALL_GATEWAYS" = "1" ]; then
	port_re="$(echo "$PRIMARY_PORTS" | tr ' ' '|')"
	[ "$ENABLE_HOME" = "1" ] && port_re="$port_re|$HOME_PORT"
	echo "listening gateway ports:"
	if command -v ss >/dev/null 2>&1; then
		ss -ltnp 2>/dev/null | grep -E ":($port_re)\b" || echo "  (none bound - check: $ASSISTANT_NAME gateway status)"
	elif command -v lsof >/dev/null 2>&1; then
		lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | grep -E ":($port_re)\b" || echo "  (none bound - check: $ASSISTANT_NAME gateway status)"
	fi
fi

echo
echo "done."
[ -z "$VKEY" ] && echo "NOTE: no virtual key set. Run ./scripts/keirouter-connect.sh <key> once you mint one in KeiRouter."
echo "Verify a model actually responds:  $ASSISTANT_NAME -z \"hi\""
echo "If that 401s, the model slug or KeiRouter provider key is the issue, not the wiring."
if [ -n "$TG_TOKEN" ]; then
	echo "Telegram: open your bot in Telegram and send it a message; '$PRIMARY_TELEGRAM_AGENT' answers."
	echo "  Lock it down: message the bot once, then set platforms.telegram.allowed_chats"
	echo "  in ~/.hermes/profiles/$PRIMARY_TELEGRAM_AGENT/config.yaml to your own chat id."
fi
