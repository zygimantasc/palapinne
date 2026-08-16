# Discovery feed built from a user's own subscriptions.
#
# Popular is computed from instance-wide watch activity (useless on a
# single-user instance) and Trending is now just YouTube's livestream feed.
# Neither reflects what the user actually follows.
#
# Instead: sample videos at random from each subscribed channel, look at what
# YouTube suggests alongside those, and keep the suggestions that come from
# channels the user does NOT already follow. Both the sampling and the final
# ordering are randomised, so every refresh gives a different set; videos that
# several different subscriptions pointed at are the one exception, and lead.
module Invidious::Discover
  extend self

  # How many subscription videos to pull recommendations from. Each seed that
  # isn't already cached costs one YouTube fetch, so this bounds page latency.
  SEED_TARGET = 24

  # With few subscriptions there aren't enough channels to reach SEED_TARGET
  # one-video-per-channel, so go deeper into each channel's back catalogue
  # instead of returning a near-empty page.
  MAX_PER_CHANNEL = 10

  RESULT_LIMIT = 16

  # Related videos carry views as display text ("194K views"), not a number,
  # so it has to be turned back into one or every card reads "0 views".
  private def parse_short_views(text : String?) : Int64
    return 0_i64 if text.nil? || text.empty?

    match = text.strip.downcase.match(/([\d.,]+)\s*([kmb])?/)
    return 0_i64 if match.nil?

    number = match[1].gsub(",", "").to_f? || return 0_i64

    case match[2]?
    when "k" then (number * 1_000).to_i64
    when "m" then (number * 1_000_000).to_i64
    when "b" then (number * 1_000_000_000).to_i64
    else          number.to_i64
    end
  end

  private record Candidate,
    id : String,
    title : String,
    author : String,
    ucid : String,
    length_seconds : Int32,
    views : Int64,
    seeds : Int32

  # The last feed built for each user. Page loads serve this verbatim, so they
  # are instant and always show the full list. Pressing refresh is the only
  # thing that rebuilds it.
  @@feeds = {} of String => Array(SearchVideo)

  # Video IDs already shown, so each refresh brings something the user has not
  # seen yet rather than reshuffling the same set.
  @@seen = {} of String => Set(String)

  @@lock = Mutex.new

  def for_user(user : User, region : String? = nil, force_refresh : Bool = false) : Array(SearchVideo)
    if !force_refresh
      if existing = @@lock.synchronize { @@feeds[user.email]? }
        return existing
      end
    end

    seen = @@lock.synchronize { @@seen[user.email]?.try(&.dup) } || Set(String).new

    feed = build(user, region, force_refresh, seen)

    # The pool of recommendations is finite, so eventually everything in it has
    # been shown. Start the rotation over instead of presenting a blank page.
    # Seeds are cached by the build above, so this pass costs nothing.
    if feed.empty? && !seen.empty?
      seen = Set(String).new
      feed = build(user, region, false, seen)
    end

    @@lock.synchronize do
      @@feeds[user.email] = feed
      @@seen[user.email] = seen.concat(feed.map(&.id))
    end

    return feed
  end

  private def build(user : User, region : String?, force_refresh : Bool, seen : Set(String)) : Array(SearchVideo)
    return [] of SearchVideo if user.subscriptions.empty?

    subscribed = user.subscriptions.to_set
    watched = user.watched.to_set

    # Spread the seed budget across however many channels are subscribed:
    # 2 channels means 10 videos each, 24+ channels means one each.
    per_channel = (SEED_TARGET / user.subscriptions.size).ceil.to_i
    per_channel = per_channel.clamp(1, MAX_PER_CHANNEL)

    seeds = Invidious::Database::ChannelVideos.select_random_per_channel(
      user.subscriptions, per_channel, SEED_TARGET
    )

    LOGGER.debug("Discover: #{seeds.size} seeds from #{user.subscriptions.size} subscriptions (#{per_channel}/channel)")

    tally = {} of String => Candidate

    seeds.each do |seed|
      # A normal page load must never touch YouTube: it uses only seeds already
      # in the video cache and silently skips the rest. Fetching them here is
      # what made this page take ~17s. Refresh is the only thing that fetches.
      next if !force_refresh && Invidious::Database::Videos.select(seed.id).nil?

      begin
        # Cached seeds are used as-is regardless of age, so the feed stays put
        # between visits.
        video = get_video(
          seed.id,
          refresh: force_refresh,
          region: region,
          force_refresh: force_refresh
        )
      rescue ex
        LOGGER.debug("Discover: skipping seed #{seed.id}: #{ex.message}")
        next
      end

      video.related_videos.each do |rv|
        id = rv["id"]?
        next if id.nil? || id.empty?
        next if watched.includes?(id)
        next if seen.includes?(id)

        ucid = rv["ucid"]? || ""
        # The whole point is discovery, so anything from a channel already
        # followed belongs in the subscriptions feed, not here.
        next if !ucid.empty? && subscribed.includes?(ucid)

        title = rv["title"]? || ""
        next if title.empty?

        if existing = tally[id]?
          tally[id] = existing.copy_with(seeds: existing.seeds + 1)
        else
          tally[id] = Candidate.new(
            id: id,
            title: title,
            author: rv["author"]? || "",
            ucid: ucid,
            length_seconds: rv["length_seconds"]?.try(&.to_i?) || 0,
            views: parse_short_views(rv["short_view_count"]?),
            seeds: 1
          )
        end
      end
    end

    # Shuffle so every refresh presents a different arrangement. Videos that
    # several different subscriptions pointed at still lead, since that is the
    # one genuine quality signal here, but everything else is random order.
    shuffled = tally.values.shuffle
    ranked = shuffled.select(&.seeds.> 1) + shuffled.select(&.seeds.<= 1)

    return ranked.first(RESULT_LIMIT).map do |c|
      SearchVideo.new({
        title:              c.title,
        id:                 c.id,
        author:             c.author,
        ucid:               c.ucid,
        published:          Time.utc,
        views:              c.views,
        description_html:   "",
        length_seconds:     c.length_seconds,
        premiere_timestamp: nil,
        author_verified:    false,
        author_thumbnail:   nil,
        badges:             VideoBadges::None,
      })
    end
  end
end
