# palapinne — a patched Invidious

This is **not** an original project. It is a lightly patched fork of
[iv-org/invidious](https://github.com/iv-org/invidious), run as a personal
single-user instance on macOS via Docker.

If you are an AI assistant picking this up cold: read this whole file before
changing anything. The patches below are the entire reason this fork exists.

## Upstream

- Source: <https://github.com/iv-org/invidious> (AGPL-3.0, written in Crystal)
- Forked at: `6865cf20` — *"Ban the use of AI to write to and/or address another Human (#5930)"*, 2026-08-12
- Release line at fork time: `v2.20260804.1`

**Read `AI_POLICY.md` in this repo before contributing anything upstream.**
Short version: AI-assisted issues and PRs must disclose the exact model used,
must be manually verified by a human, and **using AI to write messages to the
maintainers is forbidden**. If a patch here should go upstream, the human writes
the issue or PR text themselves.

## Why this fork exists

Four changes, in the order they were made.

### 1. Storyboards crash — `src/invidious/videos.cr`

`/api/v1/videos/{id}` returned HTTP 200 with a **zero-byte body** for any video
whose player response lacked a `storyboards` key (common via the `TV_SIMPLY`
fallback client). The fallback built a `JSON::Any` wrapping the *string* `"{}"`
rather than an empty Hash, so the next `container["..."]?` raised
`Expected Hash for #[]?(key : String), not String` mid-serialization.

```crystal
- container = info.dig?("storyboards") || JSON::Any.new("{}")
+ container = info.dig?("storyboards") || JSON::Any.new(Hash(String, JSON::Any).new)
```

This broke every third-party client (Yattee, Clipious, anything using the API).
**Still unfixed upstream as of the fork commit** — worth contributing back.

### 2. Related-video filter — `src/invidious/videos.cr`, `src/invidious/config.cr`

YouTube pads the watch-page sidebar with unrelated content, notably
geo-targeted filler (Lithuanian TV clips next to an English music video).

`Video#related_videos` now drops any recommendation that shares no meaningful
word with the watched video's title or YouTube tags. Same-channel videos are
always kept. Measured across 10 varied topics: ~34% dropped, median 9 of 12
kept, never fewer than 5.

There is deliberately **no "too few results, show everything" fallback** — an
earlier version had one and it restored exactly the junk this removes.

Toggle: `filter_related_videos` (default `true`). Set `false` for stock behavior.

### 3. Discover feed — `src/invidious/discover.cr` (new) + route/template/DB

Popular is computed from instance-wide watch activity (meaningless on a
single-user instance) and Trending is now just YouTube's livestream feed, since
YouTube removed the aggregated trending page. Neither reflects what the user
follows.

`/feed/discover` instead:

1. Takes the newest videos from each subscribed channel as seeds. The per-channel
   depth adapts: few subscriptions → up to 10 videos each; many → one each,
   targeting ~24 seeds total.
2. Collects what YouTube recommends alongside each seed (already topic-filtered
   by patch 2).
3. Drops anything from channels the user already follows, and anything watched.
4. Ranks by how many *different* seeds recommended the same video — being
   suggested alongside several of your subscriptions is a strong signal.

**Refresh is manual only.** Seeds are read from cache regardless of age;
`?refresh=1` forces a re-fetch. This was an explicit preference — the feed
should not shift on its own between visits.

Files: `src/invidious/discover.cr`, `src/invidious/routes/feeds.cr`
(`self.discover`), `src/invidious/routing.cr`, `src/invidious/database/channels.cr`
(`select_recent_per_channel`), `src/invidious/views/feeds/discover.ecr`,
`src/invidious/views/components/feed_menu.ecr`.

### 4. Nav and preferences

Popular and Trending removed from the feed menu; Subscriptions is the home page;
region `LT`.

Note: `default_user_preferences` in config only seeds **new** accounts. Existing
users keep their stored preferences, which live as JSON in `users.preferences`.
Changing an existing account's menu means a `jsonb_set` UPDATE, not a config edit.

## Running it

Secrets are **not** in this repo. Create `.env` in the repo root:

```sh
echo "HMAC=$(openssl rand -hex 32)"     >  .env
echo "COMPANION=$(openssl rand -hex 8)" >> .env   # must be exactly 16 chars
echo "DBPASS=$(openssl rand -hex 16)"   >> .env
chmod 600 .env
```

Then:

```sh
# Build the patched image and start (Invidious + companion + Postgres)
docker compose -f docker-compose.local.yml -f docker-compose.patched.yml up -d --build

# Logs / stop
docker compose -f docker-compose.local.yml -f docker-compose.patched.yml logs -f
docker compose -f docker-compose.local.yml -f docker-compose.patched.yml down
```

Serves on <http://127.0.0.1:3001> (3000 was taken by another container locally).
Bound to localhost only — nothing else on the network can reach it.

`docker-compose.local.yml` holds the config; `docker-compose.patched.yml`
overrides the upstream prebuilt image with a local source build. Dropping the
second file runs stock upstream, which is a quick way to A/B a patch.

**Any Crystal change needs a rebuild** — roughly 10–20 minutes on an M1. Config
changes only need a restart (~15s).

## Resyncing with upstream

```sh
git remote add upstream https://github.com/iv-org/invidious.git   # if absent
git fetch upstream
git rebase upstream/master        # or merge
```

Conflicts to expect, in likelihood order:

- `src/invidious/videos.cr` — both patches live here; patch 1 disappears if
  upstream fixes it (check `def storyboards` before re-applying)
- `src/invidious/routes/feeds.cr` and `routing.cr` — upstream edits these often
- `src/invidious/database/channels.cr` — one added method, usually clean
- `src/invidious/discover.cr` and `views/feeds/discover.ecr` — new files, never conflict

After any rebase, rebuild and verify:

```sh
curl -s http://127.0.0.1:3001/api/v1/videos/jNQXAC9IVRw | head -c 200   # must NOT be empty
```

That video has no storyboards, so an empty body means patch 1 is gone.

## Backups

`backup/subscriptions.json` — channel IDs and names, restorable by resubscribing
or via `/data_control`.

The Postgres volume (`invidious_postgresdata`) is **not** in this repo and should
not be: the `users` table holds a bcrypt password hash and `session_ids` holds
live login tokens, and this repository is public. Everything else in the database
is a rebuildable cache of YouTube data.

To back up locally instead:

```sh
docker compose -f docker-compose.local.yml -f docker-compose.patched.yml \
  exec -T invidious-db pg_dump -U kemal invidious | gzip > invidious-$(date +%F).sql.gz
```

Keep that file off GitHub.

## Gotchas

- `related_videos` filters at **read** time, so changes apply to already-cached
  videos with no re-fetch needed.
- Video info is cached in the `videos` table for 10 minutes; Discover
  deliberately ignores that expiry unless refreshed.
- Subscribed channels' videos are refreshed by a background job every 30 minutes.
- Playback depends on `invidious-companion` generating a PO token. It works from
  a residential IP; datacenter IPs are frequently blocked by YouTube, so hosting
  this on a VPS may break video playback while leaving browsing intact.
