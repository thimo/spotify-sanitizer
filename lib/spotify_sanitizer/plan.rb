# frozen_string_literal: true

require "json"
require "time"

module SpotifySanitizer
  # The reviewable output of `scan`: what would be unliked and what would be
  # liked, each with a human-readable reason. Serializes to JSON (for `apply`)
  # and to a readable text summary (for you).
  #
  # Nothing here touches Spotify — building a Plan is pure analysis.
  class Plan
    Removal = Struct.new(:id, :label, :reason, :keeper_label, keyword_init: true)
    Addition = Struct.new(:id, :label, :reason, :album, keyword_init: true)

    attr_reader :removals, :additions, :stats

    def initialize
      @removals  = []
      @additions = []
      @stats     = {}
    end

    def remove(track, reason:, keeper: nil)
      @removals << Removal.new(id: track.id, label: track.describe, reason: reason,
                               keeper_label: keeper&.describe)
    end

    def add(track, reason:)
      @additions << Addition.new(id: track.id, label: track.describe, reason: reason,
                                 album: track.album_name)
    end

    def empty? = removals.empty? && additions.empty?

    def to_h
      {
        generated_at: Time.now.iso8601,
        version:      VERSION,
        stats:        stats,
        removals:     removals.map(&:to_h),
        additions:    additions.map(&:to_h)
      }
    end

    def save_json(path)
      File.write(path, JSON.pretty_generate(to_h))
      path
    end

    def self.load_json(path)
      JSON.parse(File.read(path))
    end

    # Human-readable review document.
    def to_text
      lines = []
      lines << "spotify-sanitizer plan — #{Time.now.strftime("%Y-%m-%d %H:%M")}"
      lines << "=" * 64
      stats.each { |k, v| lines << format("  %-26s %s", k.to_s.tr("_", " "), v) }
      lines << ""

      lines << "REMOVE — #{removals.size} track(s) to unlike"
      lines << "-" * 64
      removals.each do |r|
        lines << "  ✗ #{r.label}"
        lines << "      reason: #{r.reason}"
        lines << "      keeps:  #{r.keeper_label}" if r.keeper_label
      end
      lines << "  (none)" if removals.empty?
      lines << ""

      lines << "ADD — #{additions.size} track(s) to like (album completion)"
      lines << "-" * 64
      additions.group_by(&:album).each do |album, adds|
        lines << "  #{album}"
        adds.each { |a| lines << "    + #{a.label}  — #{a.reason}" }
      end
      lines << "  (none)" if additions.empty?
      lines << ""
      lines << "Review this file, delete any line you disagree with in the JSON,"
      lines << "then run: spotify-sanitizer apply <plan.json>"
      lines.join("\n")
    end
  end
end
