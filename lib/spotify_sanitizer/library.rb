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
      @client.each_page("/me/tracks", market: @market) { |item| tracks << Track.new(item) }
      tracks
    end

    # Full tracklist of an album (for accurate completion checks).
    def album_tracks(album_id)
      tracks = []
      @client.each_page("/albums/#{album_id}/tracks", market: @market) do |item|
        # /albums/{id}/tracks items are bare track objects without the album
        # block, so graft a minimal one back on for Track to chew.
        tracks << Track.new("track" => item.merge("album" => { "id" => album_id }))
      end
      tracks
    end
  end
end
