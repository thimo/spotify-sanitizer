# frozen_string_literal: true

module SpotifySanitizer
  # The brain. Turns a list of liked tracks into a reviewable Plan by applying
  # the dedup + curation rules. Pure logic apart from the optional album-tracklist
  # fetches used to make completion checks accurate.
  #
  # Tunable knobs live in DEFAULTS — these are the heuristics worth arguing about.
  class Analyzer
    DEFAULTS = {
      # Fraction of an album's non-skit tracks you must already like before we
      # suggest completing the rest.
      completion_threshold: 0.70,
      # Tracks at or under this length are treated as skits/interludes:
      # excluded from completion math and never proposed for addition.
      skit_max_seconds:     60,
      # Drop liked tracks that are unplayable in your market (greyed out).
      drop_unplayable:      true,
      # Suggest completing partially-liked albums.
      complete_albums:      true
    }.freeze

    # album_type preference for keeper selection: lower wins.
    ALBUM_TYPE_RANK = { "album" => 0, "single" => 1, "compilation" => 2 }.freeze

    def initialize(tracks, library: nil, options: {})
      @tracks  = tracks
      @library = library
      @opts    = DEFAULTS.merge(options)
    end

    def build_plan
      plan = Plan.new
      kept = @tracks

      kept = drop_unplayable(kept, plan) if @opts[:drop_unplayable]
      kept = dedupe(kept, plan)
      complete_albums(kept, plan) if @opts[:complete_albums] && @library

      plan.stats.merge!(
        liked_tracks_scanned: @tracks.size,
        duplicates_removed:   plan.removals.count { |r| r.reason.start_with?("duplicate") },
        unplayable_removed:   plan.removals.count { |r| r.reason.start_with?("unplayable") },
        additions_suggested:  plan.additions.size,
        albums_kept:          kept.map(&:album_id).compact.uniq.size
      )
      plan
    end

    private

    def drop_unplayable(tracks, plan)
      playable, dead = tracks.partition(&:playable)
      dead.each { |t| plan.remove(t, reason: "unplayable in your market") }
      playable
    end

    # Collapse "same recording, different release" clusters down to one keeper.
    def dedupe(tracks, plan)
      kept = []
      tracks.group_by(&:fuzzy_key).each_value do |cluster|
        if cluster.size == 1
          kept << cluster.first
          next
        end

        keeper = cluster.min { |a, b| compare_versions(a, b) }
        kept << keeper
        (cluster - [keeper]).each do |loser|
          plan.remove(loser, reason: duplicate_reason(loser, keeper), keeper: keeper)
        end
      end
      kept
    end

    # Returns negative if `a` is the better keeper. Ordered rules:
    #   1. playable beats unplayable
    #   2. explicit beats clean   (your rule)
    #   3. album beats single beats compilation
    #   4. stable tie-break: the one you liked earliest
    def compare_versions(a, b)
      rank.call(a) <=> rank.call(b)
    end

    def rank
      @rank ||= lambda do |t|
        [t.playable ? 0 : 1, t.explicit ? 0 : 1, ALBUM_TYPE_RANK.fetch(t.album_type, 9), t.added_at.to_s]
      end
    end

    def duplicate_reason(loser, keeper)
      if !loser.explicit && keeper.explicit
        "duplicate — clean version, keeping explicit"
      elsif ALBUM_TYPE_RANK.fetch(loser.album_type, 9) > ALBUM_TYPE_RANK.fetch(keeper.album_type, 9)
        "duplicate — #{loser.album_type} version, keeping #{keeper.album_type}"
      else
        "duplicate — keeping one copy"
      end
    end

    # For albums you've mostly liked (ignoring skits), suggest the missing songs.
    def complete_albums(kept, plan)
      by_album = kept.select { |t| t.album_type == "album" && t.album_id }
                     .group_by(&:album_id)

      by_album.each do |album_id, liked|
        total = liked.first.album_total_tracks.to_i
        next if total.zero?

        liked_real = liked.reject { |t| t.skit?(max_seconds: @opts[:skit_max_seconds]) }
        # Rough gate before spending an API call on the full tracklist.
        next if (liked_real.size.to_f / total) < @opts[:completion_threshold]

        full = @library.album_tracks(album_id)
        liked_ids = liked.map(&:id).to_set
        missing = full.reject { |t| liked_ids.include?(t.id) }
                      .reject { |t| t.skit?(max_seconds: @opts[:skit_max_seconds]) }
        next if missing.empty? # already complete (minus skits) — leave it alone

        # Only suggest if the real completion (non-skit) clears the threshold.
        real_total = full.reject { |t| t.skit?(max_seconds: @opts[:skit_max_seconds]) }.size
        next if real_total.zero? || (liked_real.size.to_f / real_total) < @opts[:completion_threshold]

        missing.each do |t|
          have = liked_real.size
          plan.add(t, reason: "you like #{have}/#{real_total} of \"#{liked.first.album_name}\"")
        end
      end
    end
  end
end
