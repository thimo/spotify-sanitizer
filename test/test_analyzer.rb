# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/spotify_sanitizer"

module SpotifySanitizer
  # Builds saved-track hashes shaped like the Spotify API response.
  module Factory
    module_function

    def saved(name:, artist: "Artist", album: "Album", album_type: "album",
              total: 10, explicit: false, isrc: nil, duration_ms: 200_000,
              playable: true, added_at: "2020-01-01T00:00:00Z", id: nil, track_number: 1)
      id ||= "id-#{name}-#{album}-#{explicit}".gsub(/\W/, "")
      {
        "added_at" => added_at,
        "track" => {
          "id" => id, "name" => name, "explicit" => explicit,
          "duration_ms" => duration_ms, "is_playable" => playable,
          "track_number" => track_number, "disc_number" => 1,
          "external_ids" => { "isrc" => isrc },
          "artists" => [{ "name" => artist }],
          "album" => { "id" => "alb-#{album}", "name" => album,
                       "album_type" => album_type, "total_tracks" => total }
        }
      }
    end
  end

  class TestAnalyzer < Minitest::Test
    def plan_for(tracks, **opts)
      Analyzer.new(tracks.map { |t| Track.new(t) }, options: { complete_albums: false }.merge(opts)).build_plan
    end

    def test_keeps_explicit_over_clean
      tracks = [
        Factory.saved(name: "Song", explicit: false, id: "clean"),
        Factory.saved(name: "Song", explicit: true,  id: "dirty")
      ]
      plan = plan_for(tracks)
      assert_equal ["clean"], plan.removals.map(&:id)
      assert_match(/explicit/, plan.removals.first.reason)
    end

    def test_prefers_album_over_compilation
      tracks = [
        Factory.saved(name: "Hit", album_type: "compilation", album: "Greatest", id: "comp"),
        Factory.saved(name: "Hit", album_type: "album",       album: "Debut",    id: "alb")
      ]
      plan = plan_for(tracks)
      assert_equal ["comp"], plan.removals.map(&:id)
    end

    def test_drops_unplayable
      tracks = [Factory.saved(name: "Gone", playable: false, id: "dead")]
      plan = plan_for(tracks)
      assert_equal ["dead"], plan.removals.map(&:id)
      assert_match(/unplayable/, plan.removals.first.reason)
    end

    def test_distinct_songs_not_merged
      tracks = [
        Factory.saved(name: "One", id: "a"),
        Factory.saved(name: "Two", id: "b")
      ]
      plan = plan_for(tracks)
      assert_empty plan.removals
    end

    def test_remaster_collapses_with_original
      tracks = [
        Factory.saved(name: "Classic", id: "orig", added_at: "2019-01-01T00:00:00Z"),
        Factory.saved(name: "Classic - 2011 Remaster", id: "remast", added_at: "2021-01-01T00:00:00Z")
      ]
      plan = plan_for(tracks)
      assert_equal 1, plan.removals.size
    end

    def test_skit_detection
      assert Track.new(Factory.saved(name: "Interlude")).skit?
      assert Track.new(Factory.saved(name: "Short bit", duration_ms: 30_000)).skit?
      refute Track.new(Factory.saved(name: "Real Song", duration_ms: 200_000)).skit?
    end
  end
end
