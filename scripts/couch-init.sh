#!/usr/bin/env bash
#
# Configure a running CouchDB instance for the Obsidian Self-hosted LiveSync
# plugin: single-node setup, CORS for the Obsidian origins, valid-user auth,
# and a large max request size. Idempotent - safe to run repeatedly.

set -euo pipefail

cd "$(dirname "$0")/.."

# Read only the two values we need, without sourcing .env. Values like the
# bcrypt BASIC_AUTH_HASH contain '$', which would break `source` under set -u.
getenv() { grep -E "^$1=" .env | head -n1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }
COUCHDB_USER="$(getenv COUCHDB_USER)"
COUCHDB_PASSWORD="$(getenv COUCHDB_PASSWORD)"

HOST="${COUCH_HOST:-http://localhost:5984}"
AUTH=(-u "${COUCHDB_USER}:${COUCHDB_PASSWORD}")

put() {
	# put <config-path> <json-value>
	curl -fsS "${AUTH[@]}" -X PUT "${HOST}/_node/_local/_config/$1" -d "$2" >/dev/null \
		&& echo "  set $1 = $2"
}

echo "[couch-init] configuring ${HOST}"

# Wait until CouchDB is actually serving, not merely accepting TCP. Docker binds
# the port the moment the container starts, so a plain connect succeeds long
# before CouchDB answers - and on a fresh (wiped) data dir it has to build its
# system databases first. Without this, the first PUT below races startup and
# dies with "Recv failure: Connection reset by peer".
wait_up() {
	local tries=60 code
	while [ "$tries" -gt 0 ]; do
		code=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${HOST}/_up" 2>/dev/null || echo 000)
		[ "$code" = "200" ] && { echo "  couchdb is up"; return 0; }
		tries=$((tries - 1))
		sleep 2
	done
	echo "  TIMEOUT: couchdb never became ready at ${HOST}" >&2
	echo "  check:  docker logs ghiath-couchdb --tail 50" >&2
	return 1
}
wait_up

# Turn the single node into a usable single-node cluster (ignore if already done).
curl -fsS "${AUTH[@]}" -X POST "${HOST}/_cluster_setup" \
	-H "Content-Type: application/json" \
	-d '{"action":"enable_single_node"}' >/dev/null 2>&1 || true

put chttpd/require_valid_user '"true"'
put chttpd_auth/require_valid_user '"true"'
put httpd/WWW-Authenticate '"Basic realm=\"couchdb\""'
put httpd/enable_cors '"true"'
put cors/credentials '"true"'
put cors/origins '"app://obsidian.md,capacitor://localhost,http://localhost"'
put cors/methods '"GET, PUT, POST, HEAD, DELETE"'
put cors/headers '"accept, authorization, content-type, origin, referer"'
put chttpd/max_http_request_size '"4294967296"'

# Create the two system databases LiveSync expects, if missing.
for db in _users _replicator; do
	curl -fsS "${AUTH[@]}" -X PUT "${HOST}/${db}" >/dev/null 2>&1 || true
done

echo "[couch-init] done. Point the LiveSync plugin at ${HOST} with the"
echo "             COUCHDB_USER / COUCHDB_PASSWORD from .env."
