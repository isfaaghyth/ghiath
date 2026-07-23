#!/usr/bin/env bash
#
# hermes.sh - provision the two Ghiath agents on this host.
#
# SAFE BY DEFAULT. This script is idempotent and NON-DESTRUCTIVE: it creates a
# profile only if it is missing, and otherwise reconfigures the existing one in
# place. Run it after every `git pull` without losing anything.
#
# What is deliberately preserved across runs:
#   - the profile's sessions/, memories/, logs/ and workspace/
#   - the profile's .env, which holds the Telegram bot token, so an already
#     authorized bot keeps its binding and does not need re-pairing
#   - anything already in the vault; seeding never overwrites an existing file
#
# The role text in SOUL.md is written inside a marked block and replaced whole
# on each run, so re-running updates the role without duplicating it and without
# touching anything you added to that file by hand outside the block.
#
#   cp agents.conf.example agents.conf
#   ./scripts/hermes.sh [keirouter-virtual-key]
#
# The virtual key is optional; without it existing keys are left alone and a
# freshly created profile has none (set it later with keirouter-connect.sh).
# Any value in agents.conf can be overridden inline:
#   WORK_MODEL=z-ai/glm-5.1 ./scripts/hermes.sh
#
# Flags / env:
#   --reset            DESTRUCTIVE opt-in: delete and recreate both profiles.
#                      Wipes sessions, memories and the Telegram binding. Only
#                      use this to recover a genuinely broken profile.
#   INSTALL_GATEWAYS=0 configure the profiles but do not touch the gateway
#                      services (leaves a running bot completely undisturbed).

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Read a single value from a file without sourcing it (values may contain '$').
# The '|| true' is load-bearing: a missing key is normal, but grep exits 1 on no
# match and `set -o pipefail` would otherwise abort the entire script.
getenv_file() { { grep -E "^$2=" "$1" 2>/dev/null || true; } | head -n1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }

RESET=0
ARGS=()
for a in "$@"; do
	case "$a" in
		--reset) RESET=1 ;;
		*) ARGS+=("$a") ;;
	esac
done

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

# agents.conf is gitignored, so a `git pull` never updates it. A box still
# carrying the three-agent config would silently fall through to the WORK_/HOME_
# defaults below and provision two BRAND NEW profiles, orphaning the real ones
# and leaving their Telegram bots dark. Fail loudly instead.
if [ -z "${WORK_NAME:-}" ] && [ -n "${ASSISTANT_NAME:-}${ENGINEER_NAME:-}${RESEARCHER_NAME:-}${PRIMARY_VAULT:-}" ]; then
	cat >&2 <<EOF

ERROR: agents.conf is still in the old three-agent format.

  It defines ASSISTANT_NAME / ENGINEER_NAME / RESEARCHER_NAME / PRIMARY_VAULT,
  but this version expects WORK_* and HOME_*. agents.conf is gitignored, so
  'git pull' does not migrate it for you.

  Rewrite it, keeping the names of the profiles you already have so their
  sessions and Telegram bindings are reused rather than abandoned:

    WORK_NAME="\${ASSISTANT_NAME:-work}"   # the profile your bot already uses
    WORK_MODEL="opencode/z-ai/glm-5.1"
    WORK_PORT="8642"
    WORK_VAULT="\${PRIMARY_VAULT:-vault-work}"
    WORK_COLLECTION="\${PRIMARY_COLLECTION:-vault_work}"
    WORK_CONFIRM_GATE="1"

    HOME_NAME="\${HOME_NAME:-home}"
    HOME_MODEL="openrouter/deepseek/deepseek-v4-flash"
    HOME_PORT="8645"
    HOME_VAULT="\${HOME_VAULT:-vault-home}"
    HOME_COLLECTION="\${HOME_COLLECTION:-vault_home}"

  See agents.conf.example for the annotated template.

EOF
	exit 1
fi

KEIROUTER_BASE_URL="${KEIROUTER_BASE_URL:-http://localhost:20180/v1}"
VKEY="${ARGS[0]:-${KEIROUTER_VIRTUAL_KEY:-}}"
INSTALL_GATEWAYS="${INSTALL_GATEWAYS:-1}"

WORK_NAME="${WORK_NAME:-work}"
WORK_MODEL="${WORK_MODEL:-z-ai/glm-5.1}"
WORK_PORT="${WORK_PORT:-8642}"
WORK_VAULT="${WORK_VAULT:-vault-work}"
WORK_CONFIRM_GATE="${WORK_CONFIRM_GATE:-1}"

HOME_NAME="${HOME_NAME:-home}"
HOME_MODEL="${HOME_MODEL:-deepseek/deepseek-v4-flash}"
HOME_PORT="${HOME_PORT:-8645}"
HOME_VAULT="${HOME_VAULT:-vault-home}"

# Telegram tokens come from .env (secrets), never from agents.conf. The work
# agent accepts the older TELEGRAM_BOT_TOKEN name so an existing .env keeps
# working untouched.
WORK_TG_TOKEN="${WORK_TELEGRAM_BOT_TOKEN:-$(getenv_file "$ROOT/.env" WORK_TELEGRAM_BOT_TOKEN)}"
[ -z "$WORK_TG_TOKEN" ] && WORK_TG_TOKEN="${TELEGRAM_BOT_TOKEN:-$(getenv_file "$ROOT/.env" TELEGRAM_BOT_TOKEN)}"
HOME_TG_TOKEN="${HOME_TELEGRAM_BOT_TOKEN:-$(getenv_file "$ROOT/.env" HOME_TELEGRAM_BOT_TOKEN)}"

AGENTS="$WORK_NAME $HOME_NAME"

# --- preflight --------------------------------------------------------------
command -v hermes >/dev/null 2>&1 || {
	echo "hermes is not installed or not on PATH."
	echo "Install it first:"
	echo "  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
	exit 1
}
echo "hermes: $(hermes --version 2>/dev/null | head -1)"

# --- 1. reset (opt-in only) -------------------------------------------------
if [ "$RESET" = "1" ]; then
	echo
	echo "== reset (DESTRUCTIVE) =="
	echo "This deletes the profiles, including their sessions, memories, and"
	echo "Telegram bindings. Both bots will need to be re-authorized."
	printf "Type 'reset' to confirm: "
	read -r ans
	[ "$ans" = "reset" ] || { echo "aborted."; exit 0; }
	for a in $AGENTS; do
		"$a" gateway uninstall </dev/null >/dev/null 2>&1 || true
		hermes profile delete -y "$a" </dev/null >/dev/null 2>&1 || true
		echo "  deleted $a"
	done
fi

# --- 2. create (only if missing) and configure ------------------------------
echo
echo "== profiles =="
configure() {
	local name="$1" model="$2"
	if hermes profile show "$name" >/dev/null 2>&1; then
		echo "  $name exists, reconfiguring in place (sessions/memories/token kept)"
	else
		hermes profile create "$name" --description "Ghiath agent" </dev/null >/dev/null 2>&1
		echo "  $name created"
	fi
	"$name" config set model.default "$model" >/dev/null
	"$name" config set model.provider custom >/dev/null
	"$name" config set model.base_url "$KEIROUTER_BASE_URL" >/dev/null
	# Only overwrite the key when one was supplied, so a run without a key never
	# strips a working profile's credentials.
	if [ -n "$VKEY" ]; then
		"$name" config set model.api_key "$VKEY" >/dev/null
		echo "    -> $model (keirouter key updated)"
	else
		echo "    -> $model (existing api_key left as-is)"
	fi
}
configure "$WORK_NAME" "$WORK_MODEL"
configure "$HOME_NAME" "$HOME_MODEL"

# --- 3. write roles into SOUL.md --------------------------------------------
# The role lives inside a marked block. Each run strips the previous block and
# appends a fresh one, so the text stays current, never duplicates, and anything
# you wrote into SOUL.md yourself (outside the markers) survives untouched.
echo
echo "== roles (SOUL.md) =="
BEGIN_MARK="<!-- ghiath:role:begin - managed by scripts/hermes.sh, edits here are overwritten -->"
END_MARK="<!-- ghiath:role:end -->"

write_role() { # write_role <profile> ; role body on stdin
	local soul="$HOME/.hermes/profiles/$1/SOUL.md"
	local body
	body="$(cat)"
	touch "$soul"
	# Two things are stripped before the fresh block is appended:
	#  1. the previous managed block, so the role never duplicates;
	#  2. any role text left by the pre-2026-07 three-agent script, which
	#     appended without markers. That text names retired agents and the old
	#     vault layout, so leaving it in place would give the agent two
	#     contradictory sets of instructions. Everything from the first legacy
	#     heading to the end of the file was appended by that script.
	awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
		$0 == b { skip = 1; next }
		$0 == e { skip = 0; next }
		skip { next }
		/^## Your role in the Ghiath ecosystem/ { legacy = 1 }
		/^## Note format \(required\)/ { legacy = 1 }
		/^## Your role[[:space:]]*$/ { legacy = 1 }
		legacy { next }
		{ print }
	' "$soul" > "$soul.tmp"
	# Collapse trailing blank lines, then append the block with one blank line.
	awk 'NF {p = NR} {lines[NR] = $0} END {for (i = 1; i <= p; i++) print lines[i]}' "$soul.tmp" > "$soul"
	rm -f "$soul.tmp"
	{
		printf '\n%s\n' "$BEGIN_MARK"
		printf '%s\n' "$body"
		printf '%s\n' "$END_MARK"
	} >> "$soul"
	echo "  wrote role block -> $1"
}

# Absolute paths. A gateway runs as a background service, so its working
# directory is not the repo: a relative "vault-work/" would resolve somewhere
# else entirely and the agent's notes would vanish silently.
WORK_VAULT_ABS="$ROOT/$WORK_VAULT"
HOME_VAULT_ABS="$ROOT/$HOME_VAULT"

# The confirmation gate. This is the whole point of the work agent's design:
# it plans out loud, stops, and does not touch anything until told to go.
confirm_gate() {
	cat <<'EOF'

## Confirmation gate (MANDATORY)

Before you execute any technical task, you STOP and ask for confirmation in the
same Telegram chat, then wait for the reply.

"Technical" means anything that changes state or runs code: writing or editing
files, running shell commands, installing or upgrading packages, any git
operation that writes (commit, push, branch, rebase, reset), deploying,
restarting a service, calling an API that mutates data, or changing
configuration. Reading, searching, summarizing, explaining, and planning are NOT
technical tasks - do those immediately and freely, no confirmation needed.

The protocol, every single time:

1. PLAN. Reply with a short plan: what you understood the request to be, the
   exact steps you intend to take, and which files or services each step
   touches. Ten lines at most. Do not begin any of it.
2. ASK. End that message with exactly this line, on its own:
   Confirm to proceed? (reply "go")
3. WAIT. Do nothing at all until you get a reply. If the reply is anything other
   than a clear go-ahead, treat it as "no": answer what was asked or revise the
   plan, then ask again.
4. EXECUTE. Once confirmed, carry out the plan you showed - that plan only.
   If the work turns out to need a step you did not list, stop and return to
   step 1 for that new step.

One confirmation covers one plan. It never carries over to the next request, and
it never becomes standing permission. Urgency does not override this gate: if
something looks urgent, say so in the plan, then still wait.
EOF
}

{
	cat <<EOF

## Your role

You are $WORK_NAME, Isfa's personal work assistant. You are his alone: this is
the technical side of his life, and nobody else talks to you.

You handle the whole job yourself - thinking, researching, planning, writing,
and executing. There are no other agents to delegate to and no handoffs; if a
task needs doing, you are the one who does it.

You own the vault at $WORK_VAULT_ABS/. That is your memory and your workspace.
Save anything worth keeping there as a Markdown note, and always use that
absolute path, never a relative one. Search it before answering a question that
past-you may already have answered.
EOF
	[ "$WORK_CONFIRM_GATE" = "1" ] && confirm_gate
	cat <<EOF

## Note format

Begin every Markdown note you write in the vault with this front-matter, then
the body:

\`\`\`
---
type: task        # task | result | note
status: open      # open | doing | done
owner: $WORK_NAME
from: $WORK_NAME
created: YYYY-MM-DD
tags: []
---
\`\`\`

This is what the dashboard's Bases views read. Keep "status" honest: "open" for
something still to do, "done" once it is finished.
EOF
} | write_role "$WORK_NAME"

write_role "$HOME_NAME" <<EOF

## Your role

You are $HOME_NAME, the household assistant. You are shared: Isfa and his wife
both talk to you, so never assume which of them you are speaking with, and never
assume something one of them told you is private from the other. If who is
asking actually changes your answer, just ask.

You help with everyday life: reminders, shopping and to-do lists, plans,
appointments, quick questions, and journaling. Keep your answers warm, short,
and in plain language. Match the language you are spoken to in. You are not a
technical assistant - if a question is really about code, servers, or work,
say so kindly and leave it.

You work only inside your own vault, $HOME_VAULT_ABS/. You do not know about,
and cannot reach, any other vault or agent. Always write notes to that absolute
path, never a relative one.

## Note format

Begin every note you save with this front-matter, then the body:

\`\`\`
---
type: note
status: done
owner: $HOME_NAME
from: $HOME_NAME
created: YYYY-MM-DD
tags: []
---
\`\`\`
EOF

# --- 4. seed skills ---------------------------------------------------------
# hermes profiles keep their own skills directory. Two sources, both copied into
# each agent's skills/custom:
#   skills/        shared skills, tracked in git (e.g. reminders)
#   skills-local/  PRIVATE skills, gitignored - personal/proprietary content
#                  that must never be pushed (see README "Private data & skills")
# Copying is additive; it never removes a skill you placed there by hand.
for src in skills skills-local; do
	[ -d "$ROOT/$src" ] || continue
	echo
	echo "== seed $src =="
	for a in $AGENTS; do
		dest="$HOME/.hermes/profiles/$a/skills/custom"
		mkdir -p "$dest"
		cp -R "$ROOT/$src/." "$dest/"
		echo "  seeded $(cd "$ROOT/$src" && ls -d */ 2>/dev/null | tr -d / | tr '\n' ' ')-> $a"
	done
done

# --- 5. seed hermes cron scripts --------------------------------------------
# `hermes cron --script <name>` resolves names under ~/.hermes/scripts/. These
# tick scripts are what drive reminders; see REMINDERS.md.
if [ -d "$ROOT/scripts/hermes-cron" ]; then
	echo
	echo "== seed hermes cron scripts =="
	"$ROOT/scripts/seed-cron.sh"
fi

# --- 6. seed the vaults -----------------------------------------------------
# The vaults are created at runtime and gitignored, so seed the scaffolding
# here. Idempotent and strictly additive: an existing file is NEVER overwritten,
# so your real notes and any dashboard you customized are safe.
echo
echo "== seed vaults =="

seed() { # seed <path> ; reads content from stdin, skips if the file exists
	if [ -e "$1" ]; then
		# Drain stdin so the heredoc does not end up on the terminal.
		cat >/dev/null
		echo "  keep   ${1#$ROOT/}"
	else
		cat > "$1"
		echo "  create ${1#$ROOT/}"
	fi
}

mkdir -p "$WORK_VAULT_ABS/reminders"

seed "$WORK_VAULT_ABS/000-Dashboard.md" <<'EOF'
---
type: note
status: done
owner: you
from: you
created: 2025-01-01
tags: [dashboard]
---

# Work Dashboard

Quick capture and a window into what the assistant is doing. The live views are
the Bases below; this note is just a landing pad.

## Quick capture

-

## Open tasks

![[tasks.base]]

## Recent activity

![[activity.base]]
EOF

seed "$WORK_VAULT_ABS/tasks.base" <<'EOF'
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
      - created
    sort:
      - property: created
        direction: DESC
EOF

seed "$WORK_VAULT_ABS/activity.base" <<'EOF'
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
      - created
    sort:
      - property: created
        direction: DESC
EOF

mkdir -p "$HOME_VAULT_ABS/reminders"

seed "$HOME_VAULT_ABS/000-Dashboard.md" <<EOF
---
type: note
status: done
owner: $HOME_NAME
from: $HOME_NAME
created: 2025-01-01
tags: [dashboard]
---

# Home Dashboard

Quick capture and a window into recent notes.

## Quick capture

-

## Recent notes

![[notes.base]]
EOF

seed "$HOME_VAULT_ABS/notes.base" <<'EOF'
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

# --- 7. telegram ------------------------------------------------------------
# Write a bot token into a profile's .env. hermes reads it from there and
# connects the bot when that profile's gateway runs. Every other line in that
# file is preserved, and a profile with no new token is left completely alone -
# an already-authorized bot keeps working.
echo
echo "== telegram =="
set_tg_token() { # set_tg_token <profile> <token>
	local penv="$HOME/.hermes/profiles/$1/.env"
	touch "$penv"
	if [ "$(getenv_file "$penv" TELEGRAM_BOT_TOKEN)" = "$2" ]; then
		echo "  $1: token already current, left untouched"
		return
	fi
	grep -v '^TELEGRAM_BOT_TOKEN=' "$penv" > "$penv.tmp" 2>/dev/null || true
	echo "TELEGRAM_BOT_TOKEN=$2" >> "$penv.tmp"
	mv "$penv.tmp" "$penv"
	echo "  $1: bot token set; it connects when that gateway runs"
}
if [ -n "$WORK_TG_TOKEN" ]; then
	set_tg_token "$WORK_NAME" "$WORK_TG_TOKEN"
else
	echo "  $WORK_NAME: no token in .env; existing binding (if any) left untouched"
fi
if [ -n "$HOME_TG_TOKEN" ]; then
	set_tg_token "$HOME_NAME" "$HOME_TG_TOKEN"
else
	echo "  $HOME_NAME: no HOME_TELEGRAM_BOT_TOKEN in .env; existing binding (if any) left untouched"
fi

# --- 8. gateways ------------------------------------------------------------
# Each gateway needs its own port; two cannot share one. Fully non-interactive
# via flags, so it cannot hang.
if [ "$INSTALL_GATEWAYS" = "1" ]; then
	echo
	echo "== gateways =="
	PORT="$WORK_PORT" "$WORK_NAME" gateway install --force --start-now --start-on-login </dev/null >/dev/null 2>&1 || true
	PORT="$HOME_PORT" "$HOME_NAME" gateway install --force --start-now --start-on-login </dev/null >/dev/null 2>&1 || true
	echo "  requested $WORK_NAME:$WORK_PORT $HOME_NAME:$HOME_PORT"
fi

# --- 9. status --------------------------------------------------------------
echo
echo "== status =="
name_re="$(echo "$AGENTS default" | tr ' ' '|')"
hermes profile list 2>/dev/null | grep -E "Profile|$name_re" || true
if [ "$INSTALL_GATEWAYS" = "1" ]; then
	port_re="$WORK_PORT|$HOME_PORT"
	echo "listening gateway ports:"
	if command -v ss >/dev/null 2>&1; then
		ss -ltnp 2>/dev/null | grep -E ":($port_re)\b" || echo "  (none bound - check: $WORK_NAME gateway status)"
	elif command -v lsof >/dev/null 2>&1; then
		lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | grep -E ":($port_re)\b" || echo "  (none bound - check: $WORK_NAME gateway status)"
	fi
fi

# Ghiath used to run a three-agent team. If those profiles are still here they
# are inert - nothing routes to them - but they still hold old sessions, so
# removing them is left as a deliberate manual step.
echo
legacy=""
for old in assistant engineer researcher ippang kuli pakprof; do
	case " $AGENTS " in *" $old "*) continue ;; esac
	hermes profile show "$old" >/dev/null 2>&1 && legacy="$legacy $old"
done
if [ -n "$legacy" ]; then
	echo "NOTE: retired profiles still present:$legacy"
	echo "  They are unused now. Nothing here touches them. To remove one yourself:"
	for old in $legacy; do
		echo "    $old gateway uninstall && hermes profile delete -y $old"
	done
fi

echo
echo "done."
[ -z "$VKEY" ] && echo "NOTE: no virtual key passed; existing keys were kept. Set one with ./scripts/keirouter-connect.sh <key>."
echo "Verify a model responds:  $WORK_NAME -z \"hi\""
echo "If that 401s, the model slug or the KeiRouter provider key is the issue, not the wiring."
if [ -n "$WORK_TG_TOKEN" ] || [ -n "$HOME_TG_TOKEN" ]; then
	echo "Telegram: message each bot to test."
	echo "  Lock them down: set platforms.telegram.allowed_chats in"
	echo "  ~/.hermes/profiles/<agent>/config.yaml (work: your chat id only;"
	echo "  home: yours and your wife's)."
fi
