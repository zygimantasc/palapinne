#!/usr/bin/env bash
# Dump the subscriptions of one account to backup/, in two formats:
#
#   subscriptions.json          human-readable, for reading a diff
#   subscriptions.newpipe.json  importable at /data_control on any instance
#
# Usage:  ./backup/export-subscriptions.sh [account-email]
#
# Run it after subscribing to anything, then commit the result. That keeps the
# repo the source of truth, so a fresh machine restores the same set.

set -euo pipefail

EMAIL="${1:-silicone}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f docker-compose.local.yml -f docker-compose.patched.yml)

cd "$DIR"

# LEFT JOIN: a channel can be subscribed before its metadata has been fetched,
# and it must still make it into the backup.
"${COMPOSE[@]}" exec -T invidious-db psql -U kemal -d invidious -tAc "
  SELECT json_agg(json_build_object('ucid', s.ucid, 'author', COALESCE(c.author, s.ucid)) ORDER BY c.author)
  FROM (SELECT unnest(subscriptions) AS ucid FROM users WHERE email='${EMAIL}') s
  LEFT JOIN channels c ON c.id = s.ucid;" > /tmp/subs_raw.json

python3 - "$EMAIL" <<'PY'
import json, sys

email = sys.argv[1]
channels = json.load(open('/tmp/subs_raw.json')) or []

with open('backup/subscriptions.json', 'w') as f:
    json.dump({
        'note': 'Invidious subscriptions backup. Import subscriptions.newpipe.json at /data_control, or run backup/restore-subscriptions.sh.',
        'account': email,
        'count': len(channels),
        'channels': channels,
    }, f, indent=2, ensure_ascii=False)
    f.write('\n')

# Invidious' NewPipe importer only reads url + name, so this minimal shape is
# enough and stays valid for any instance.
with open('backup/subscriptions.newpipe.json', 'w') as f:
    json.dump({
        'app_version': '0.0.0',
        'app_version_int': 0,
        'subscriptions': [
            {'service_id': 0,
             'url': f"https://www.youtube.com/channel/{c['ucid']}",
             'name': c['author']}
            for c in channels
        ],
    }, f, indent=2, ensure_ascii=False)
    f.write('\n')

print(f'exported {len(channels)} channels for {email}')
PY
