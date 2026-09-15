#!/usr/bin/env bash
# Live update of the application's app.* namespaces without a restart, through
# keeper's sync (filesystem -> registry = "upload"; NEVER "download", which
# writes the registry back over the source files).
#
#   tools/live-update.sh <namespace> [migration-id ...]
#   tools/live-update.sh app.desktop
#   tools/live-update.sh app.desktop app.desktop:01_ssh_keys
#
# 1. adds the namespace to keeper's managed namespaces (by config they are
#    app.deps only)
# 2. uploads ./src/ for the managed namespaces into the running registry
# 3. puts the managed namespaces back as they were (also on failure)
# 4. runs the named migrations (a dry run first, then for real)
#
# What it cannot do: a changed `process.service` keeps running its old code
# (the supervisor swaps only the lifecycle config); new services start. Windows
# and libraries pick the new code up when a process is spawned — reopen the
# window. A NEW entry that a running compositor needs (a widget, an image
# pack) still wants a restart.
#
# Environment:
#   CHICAGO_APP_API    API base, default http://127.0.0.1:8099/api/v1
#   KICKSIDE_API_TOKEN operator token (24 h); read from .env.local if unset —
#                      see .env.example for how to mint one
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [ -z "${KICKSIDE_API_TOKEN:-}" ] && [ -f .env.local ]; then
  set -a; . ./.env.local; set +a
fi
: "${KICKSIDE_API_TOKEN:?KICKSIDE_API_TOKEN is not set (export it or put it in .env.local; see .env.example)}"

API="${CHICAGO_APP_API:-http://127.0.0.1:8099/api/v1}"
AUTH="Authorization: Bearer $KICKSIDE_API_TOKEN"
NS="${1:?namespace, e.g. app.desktop}"; shift || true

json() { python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d, ensure_ascii=False)[:1500])"; }

before=$(curl -sf -H "$AUTH" "$API/keeper/sync/config" \
  | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['managed_namespaces']))")
echo "managed before: $before"
restore() {
  curl -sf -X PUT -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"managed_namespaces\": $before}" "$API/keeper/sync/config" >/dev/null \
    && echo "managed restored: $before"
}
trap restore EXIT

with=$(python3 -c "import json,sys; l=json.loads(sys.argv[1]); n=sys.argv[2]; print(json.dumps(l if n in l else l+[n]))" "$before" "$NS")
curl -sf -X PUT -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"managed_namespaces\": $with}" "$API/keeper/sync/config" | json
echo "--- state"; curl -sf -H "$AUTH" "$API/keeper/sync/state" | json
# UPLOAD only. There is a `download` next to it that writes the registry over
# ./src/ — never call it.
echo "--- upload"; curl -s -X POST -H "$AUTH" "$API/keeper/sync/upload" | json

for id in "$@"; do
  echo "--- migration $id (dry run)"
  curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"entry_ids\":[\"$id\"],\"operation\":\"up\",\"dry_run\":true}" "$API/keeper/hub/migrations/run" | json
  echo "--- migration $id"
  curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"entry_ids\":[\"$id\"],\"operation\":\"up\"}" "$API/keeper/hub/migrations/run" | json
done
