#!/usr/bin/env bash
# Apply backup/subscriptions.json to a running instance.
#
#   ./backup/restore-subscriptions.sh [account] [--mirror] [--yes]
#
#   default    add anything missing, never remove   (safe, use on a new machine)
#   --mirror   make the account match the file exactly, removing subscriptions
#              that are not in it  (use when the file is the source of truth)
#   --yes      skip the confirmation prompt in --mirror mode
#
# Either way the change is printed before it is applied. The account must
# already exist - register through the web UI first.
#
# No shell access? Upload backup/subscriptions.newpipe.json at /data_control ->
# "Import NewPipe data". That path is additive only.

set -euo pipefail

EMAIL="silicone"
MIRROR=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --mirror) MIRROR=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) EMAIL="$arg" ;;
  esac
done

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f docker-compose.local.yml -f docker-compose.patched.yml)
cd "$DIR"

psql_q() { "${COMPOSE[@]}" exec -T invidious-db psql -U kemal -d invidious -tAc "$1"; }

if [ "$(psql_q "SELECT count(*) FROM users WHERE email='${EMAIL}';" | tr -d '[:space:]')" = "0" ]; then
  echo "No such account: ${EMAIL}. Register it through the web UI first." >&2
  exit 1
fi

INCOMING=$(python3 -c "
import json
d = json.load(open('backup/subscriptions.json'))
print(','.join(sorted(c['ucid'] for c in d['channels'])))
")
[ -n "$INCOMING" ] || { echo "backup/subscriptions.json lists no channels." >&2; exit 1; }

CURRENT=$(psql_q "SELECT coalesce(array_to_string(subscriptions, ','), '') FROM users WHERE email='${EMAIL}';" | tr -d '[:space:]')

# Show the change before touching anything.
python3 - "$CURRENT" "$INCOMING" "$MIRROR" <<'PY'
import sys
cur = set(filter(None, sys.argv[1].split(',')))
inc = set(filter(None, sys.argv[2].split(',')))
mirror = sys.argv[3] == '1'
add, remove = inc - cur, cur - inc
print(f"account has {len(cur)}, file has {len(inc)}")
for u in sorted(add):
    print(f"  + {u}")
if mirror:
    for u in sorted(remove):
        print(f"  - {u}")
elif remove:
    print(f"  ({len(remove)} in the account but not the file, kept - pass --mirror to remove)")
if not add and not (mirror and remove):
    print("  nothing to change")
PY

if [ "$MIRROR" = "1" ] && [ "$ASSUME_YES" != "1" ]; then
  read -r -p "Apply, removing anything not in the file? [y/N] " reply
  case "$reply" in [yY]*) ;; *) echo "aborted"; exit 0 ;; esac
fi

if [ "$MIRROR" = "1" ]; then
  SET_EXPR="ARRAY(SELECT DISTINCT unnest(incoming))"
else
  SET_EXPR="ARRAY(SELECT DISTINCT unnest(subscriptions || incoming))"
fi

"${COMPOSE[@]}" exec -T invidious-db psql -U kemal -d invidious -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
DECLARE
  target   text   := '${EMAIL}';
  incoming text[] := string_to_array('${INCOMING}', ',');
BEGIN
  -- Channel rows must exist or the subscriptions feed ignores them. Invidious
  -- replaces the placeholder author on its next refresh.
  INSERT INTO channels (id, author, updated, deleted, subscribed)
  SELECT u, u, now(), false, now() FROM unnest(incoming) AS u
  ON CONFLICT (id) DO UPDATE SET deleted = false;

  UPDATE users SET subscriptions = ${SET_EXPR} WHERE email = target;
END
\$\$;
SQL

psql_q "SELECT array_length(subscriptions, 1) || ' channels now subscribed' FROM users WHERE email='${EMAIL}';"
echo "Open /feed/subscriptions to fetch their videos."
