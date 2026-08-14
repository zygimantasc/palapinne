# Discovery feed built from a user's own subscriptions.
#
# Popular is computed from instance-wide watch activity (useless on a
# single-user instance) and Trending is now just YouTube's livestream feed.
# Neither reflects what the user actually follows.
#
# Instead: take the newest video from each subscribed channel, look at what
# YouTube suggests alongside those, and keep the suggestions that come from
# channels the user does NOT already follow. A video suggested alongside
# several different subscriptions ranks higher than one seen once.
module Invidious::Discover
  extend self

  # How many subscription videos to pull recommendations from. Each seed that
  # isn't already cached costs one YouTube fetch, so this bounds page latency.
  SEED_TARGET = 24

  # With few subscriptions there aren't enough channels to reach SEED_TARGET
  # one-video-per-channel, so go deeper into each channel's back catalogue
  # instead of returning a near-empty page.
  MAX_PER_CHANNEL = 10

  RESULT_LIMIT = 60

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

  # force_refresh bypasses the 10 minute video cache so the user can pull a
  # genuinely new set on demand. It costs one YouTube fetch per seed, so it is
  # only ever driven by an explicit click, never by a normal page load.
  def for_user(user : User, region : String? = nil, force_refresh : Bool = false) : Array(SearchVideo)
    return [] of SearchVideo if user.subscriptions.empty?

    subscribed = user.subscriptions.to_set
    watched = user.watched.to_set

    # Spread the seed budget across however many channels are subscribed:
    # 2 channels means 10 videos each, 24+ channels means one each.
    per_channel = (SEED_TARGET / user.subscriptions.size).ceil.to_i
    per_channel = per_channel.clamp(1, MAX_PER_CHANNEL)

    seeds = Invidious::Database::ChannelVideos.select_recent_per_channel(
      user.subscriptions, per_channel, SEED_TARGET
    )

    LOGGER.debug("Discover: #{seeds.size} seeds from #{user.subscriptions.size} subscriptions (#{per_channel}/channel)")

    tally = {} of String => Candidate

    seeds.each do |seed|
      begin
        # `refresh: false` means an already-cached seed is used as-is no matter
        # how old it is, so the feed only changes when the user asks it to.
        # Seeds missing from the cache entirely are still fetched.
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

    # Being recommended alongside several different subscriptions is a far
    # stronger signal than a single appearance, so that drives the order.
    ranked = tally.values.sort_by { |c| {-c.seeds, c.title} }

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
