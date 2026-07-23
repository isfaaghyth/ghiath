#!/usr/bin/env bash
#
# seed-cron.sh - copy the hermes cron tick scripts into ~/.hermes/scripts/.
#
# `hermes cron --script <name>` resolves names under ~/.hermes/scripts/, so the
# tick scripts must live there. This only copies files: it does not touch
# profiles, gateways, or Telegram bindings. Run it after every `git pull` that
# changes a script under scripts/hermes-cron/. scripts/hermes.sh calls it too.
#
#   ./scripts/seed-cron.sh        (or: make seed-cron)
#
# Registering the job itself is a one-time step (see REMINDERS.md). Use a cron
# EXPRESSION, not a bare duration: '1m' means "once, a minute from now".
#   hermes cron create '* * * * *' --no-agent --script reminder-tick.py \
#       --deliver telegram --name ghiath-reminders

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/hermes-cron"
DEST="$HOME/.hermes/scripts"

if [ ! -d "$SRC" ]; then
	echo "no scripts to seed at $SRC" >&2
	exit 1
fi

mkdir -p "$DEST"
copied=0
for f in "$SRC"/*.py; do
	[ -e "$f" ] || continue
	cp "$f" "$DEST/"
	echo "  seeded $(basename "$f") -> $DEST/"
	copied=$((copied + 1))
done

if [ "$copied" -eq 0 ]; then
	echo "no *.py found in $SRC" >&2
	exit 1
fi

echo "done. $copied script(s) in $DEST"
echo "check the jobs:  hermes cron list"
