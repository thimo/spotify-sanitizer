# frozen_string_literal: true

module SpotifySanitizer
  # A liked track, flattened from the Spotify "saved track" object into just
  # the fields the analyzer reasons about.
  class Track
    attr_reader :id, :name, :artists, :album_id, :album_name, :album_type,
                :album_total_tracks, :track_number, :disc_number, :duration_ms,
                :explicit, :isrc, :playable, :added_at, :uri

    def initialize(saved)
      t = saved["track"] || saved
      album = t["album"] || {}
      @id                 = t["id"]
      @name               = t["name"].to_s
      @artists            = (t["artists"] || []).map { |a| a["name"] }
      @album_id           = album["id"]
      @album_name         = album["name"].to_s
      @album_type         = album["album_type"]            # album | single | compilation
      @album_total_tracks = album["total_tracks"]
      @track_number       = t["track_number"]
      @disc_number        = t["disc_number"]
      @duration_ms        = t["duration_ms"].to_i
      @explicit           = t["explicit"] ? true : false
      @isrc               = t.dig("external_ids", "isrc")
      # `is_playable` only appears when a market is supplied; treat missing as playable.
      @playable           = t.key?("is_playable") ? t["is_playable"] : true
      @added_at           = saved["added_at"]
      @uri                = t["uri"]
    end

    def primary_artist = artists.first.to_s

    # Likely a skit/interlude/etc — excluded from album-completion math and never
    # proposed for addition. Heuristic: very short, or a telltale title.
    SKIT_PATTERN = /\b(skit|interlude|intro|outro|prelude|reprise|segue)\b/i

    def skit?(max_seconds: 60)
      duration_ms <= max_seconds * 1000 || name.match?(SKIT_PATTERN)
    end

    # Normalized key for fuzzy "same song, different release" clustering.
    # Strips remaster/version cruft and punctuation so an album cut and its
    # single/remaster collapse together; duration bucket guards against
    # genuinely different songs that share a title.
    VERSION_CRUFT = /\s*[-(\[].*?(remaster|remastered|mono|stereo|deluxe|edit|version|anniversary|mix|live|radio).*?[)\]]?$/i

    def fuzzy_key
      title = name.downcase
      title = title.sub(VERSION_CRUFT, "")
      title = title.gsub(/[^a-z0-9]+/, " ").strip
      "#{primary_artist.downcase.gsub(/[^a-z0-9]+/, " ").strip}|#{title}|#{(duration_ms / 5000.0).round}"
    end

    def to_h
      {
        id: id, name: name, artists: artists, album: album_name,
        album_type: album_type, explicit: explicit, isrc: isrc,
        duration_ms: duration_ms, added_at: added_at
      }
    end

    def describe
      tag = explicit ? "E" : " "
      "[#{tag}] #{primary_artist} — #{name} (#{album_name}) #{(duration_ms / 1000)}s"
    end
  end
end
