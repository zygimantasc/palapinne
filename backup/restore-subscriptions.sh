#!/usr/bin/env bash
# Restore subscriptions from backup/subscriptions.json into a running instance.
#
# Usage:  ./backup/restore-subscriptions.sh [account-email]
#
# The account must already exist - register through the web UI first. Existing
# subscriptions are kept; this adds the backed-up ones and de-duplicates, so
# running it twice is harmless.
#
# The alternative, needing no shell access, is uploading
# backup/subscriptions.newpipe.json at /data_control -> "Import NewPipe data".

set -euo pipefail

EMAIL="${1:-silicone}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f docker-compose.local.yml -f docker-compose.patched.yml)

cd "$DIR"

UCIDS=$(python3 -c "
import json
d = json.load(open('backup/subscriptions.json'))
print(','.join(c['ucid'] for c in d['channels']))
")

if [ -z "$UCIDS" ]; then
  echo "backup/subscriptions.json lists no channels; nothing to restore." >&2
  exit 1
fi

echo "restoring $(tr ',' '\n' <<<"$UCIDS" | wc -l | tr -d ' ') channels to ${EMAIL}..."

"${COMPOSE[@]}" exec -T invidious-db psql -U kemal -d invidious -v ON_ERROR_STOP=1 <<SQL
DO \$\$
DECLARE
  target text := '${EMAIL}';
  incoming text[] := string_to_array('${UCIDS}', ',');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE email = target) THEN
    RAISE EXCEPTION 'No such account: %. Register it through the web UI first.', target;
  END IF;

  -- Channel rows must exist or the subscriptions feed ignores them. Invidious
  -- fills in the real author on its next refresh.
  INSERT INTO channels (id, author, updated, deleted, subscribed)
  SELECT u, u, now(), false, now() FROM unnest(incoming) AS u
  ON CONFLICT (id) DO UPDATE SET deleted = false;

  UPDATE users
  SET subscriptions = ARRAY(SELECT DISTINCT unnest(subscriptions || incoming))
  WHERE email = target;
END
\$\$;
SQL

"${COMPOSE[@]}" exec -T invidious-db psql -U kemal -d invidious -tAc \
  "SELECT array_length(subscriptions, 1) || ' channels now subscribed' FROM users WHERE email='${EMAIL}';"

echo "Open /feed/subscriptions to trigger the first fetch of their videos."
