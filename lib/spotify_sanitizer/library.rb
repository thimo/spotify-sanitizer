# frozen_string_literal: true

module SpotifySanitizer
  # Reads the user's saved ("liked") tracks and albums from Spotify.
  class Library
    def initialize(client = Client.new, market: "from_token")
      @client = client
      @market = market
    end

    # All liked songs as Track objects. Passing a market makes Spotify populate
    # `is_playable`, which the analyzer uses to drop unavailable tracks.
    def liked_tracks
      tracks = []
      @client.each_page("/me/tracks", { market: @market }) { |item| tracks << Track.new(item) }
      tracks
    end

    # Full tracklist of an album (for accurate completion checks).
    def album_tracks(album_id)
      tracks = []
      @client.each_page("/albums/#{album_id}/tracks", { market: @market }) do |item|
        # /albums/{id}/tracks items are bare track objects without the album
        # block, so graft a minimal one back on for Track to chew.
        tracks << Track.new("track" => item.merge("album" => { "id" => album_id }))
      end
      tracks
    end

    # Spotify's search endpoint rejects limit > 10 (despite docs claiming 50);
    # an ISRC only ever has a handful of releases, so 10 is plenty.
    SEARCH_LIMIT = 10

    # An ISRC is supposed to pin one recording, but Spotify's catalog has
    # recycled/bootleg ISRCs — so an isrc: hit can be a different recording
    # entirely. Guard with a duration sanity-check: the same master has the
    # same length (±this many ms).
    DURATION_TOLERANCE_MS = 3000

    # Find a playable stand-in for an unplayable track: the *same recording*
    # (same ISRC, same length) on a different release that plays in @market.
    # Returns a Track or nil. Read-only — only `apply` ever likes it.
    def find_alternative(track)
      return nil if track.isrc.to_s.empty?

      search_tracks("isrc:#{track.isrc}").find do |c|
        c.playable && c.id != track.id &&
          (c.duration_ms - track.duration_ms).abs <= DURATION_TOLERANCE_MS
      end
    end

    private

    def search_tracks(query)
      res = @client.get("/search", { q: query, type: "track", market: @market, limit: SEARCH_LIMIT })
      (res.dig("tracks", "items") || []).map { |item| Track.new(item) }
    end
  end
end
