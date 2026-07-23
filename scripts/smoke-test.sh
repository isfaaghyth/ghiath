#!/usr/bin/env bash
#
# Ghiath smoke test. Exercises every locally-reachable service and reports
# pass/fail. Exits non-zero if anything is down. Does NOT need API keys.

set -uo pipefail

cd "$(dirname "$0")/.."
# Read only what we need instead of sourcing .env (bcrypt hashes contain '$'
# and would break a naive `source`).
getenv() { grep -E "^$1=" .env 2>/dev/null | head -n1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }
COUCHDB_USER="$(getenv COUCHDB_USER)"
COUCHDB_PASSWORD="$(getenv COUCHDB_PASSWORD)"
# The collection names are configurable; prefer .env, then agents.conf, then the
# default. Keeps the check correct even after a rename.
conf_val() { grep -E "^$1=" "$2" 2>/dev/null | head -n1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }
resolve() { # resolve <VAR> <fallback>
	local v
	v="$(getenv "$1")"
	[ -z "$v" ] && v="$(conf_val "$1" agents.conf)"
	[ -z "$v" ] && v="$2"
	echo "$v"
}
WORK_COLLECTION="$(resolve WORK_COLLECTION vault_work)"
HOME_COLLECTION="$(resolve HOME_COLLECTION vault_home)"

PASS=0
FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

check_http() { # name url expected_code
	local code
	code=$(curl -s -o /dev/null -w '%{http_code}' "$2" 2>/dev/null || echo 000)
	[ "$code" = "$3" ] && ok "$1 ($2 -> $code)" || bad "$1 ($2 -> $code, want $3)"
}

echo "Ghiath smoke test"
echo "-----------------"

echo "Docker services:"
for svc in couchdb livesync-bridge qdrant qdrant-indexer qdrant-indexer-home keirouter; do
	status=$(docker compose ps --format '{{.Service}} {{.Status}}' 2>/dev/null | awk -v s="$svc" '$1==s{$1="";print}')
	echo "$status" | grep -qiE 'up|healthy' && ok "$svc running:$status" || bad "$svc not running"
done
# n8n is an opt-in add-on now; report it but never fail on it.
n8n_status=$(docker compose ps --format '{{.Service}} {{.Status}}' 2>/dev/null | awk '$1=="n8n"{$1="";print}')
if [ -n "$n8n_status" ]; then
	ok "n8n running (add-on):$n8n_status"
else
	echo "  SKIP  n8n (add-on, not started - this is the default)"
fi

echo "HTTP endpoints:"
check_http "qdrant health"      "http://localhost:6333/healthz" "200"
check_http "qdrant collections" "http://localhost:6333/collections" "200"
# 401 is the healthy signal here: server up AND require_valid_user enforced.
# A down server returns 000. Authenticated access is verified separately below.
check_http "couchdb reachable"  "http://localhost:5984/" "401"
check_http "keirouter"          "http://localhost:20180/" "200"

echo "Semantic index:"
for coll in "$WORK_COLLECTION" "$HOME_COLLECTION"; do
	points=$(curl -s "http://localhost:6333/collections/$coll" 2>/dev/null \
		| python3 -c "import sys,json;print(json.load(sys.stdin)['result']['points_count'])" 2>/dev/null || echo "")
	if [ -n "$points" ]; then ok "$coll collection exists ($points points)"; else bad "$coll collection missing (indexer may still be starting)"; fi
done

echo "CouchDB auth:"
if curl -fsS -u "${COUCHDB_USER:-admin}:${COUCHDB_PASSWORD:-}" "http://localhost:5984/_all_dbs" >/dev/null 2>&1; then
	ok "couchdb authenticated query"
else
	bad "couchdb auth failed (check COUCHDB_PASSWORD in .env)"
fi

echo "-----------------"
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
