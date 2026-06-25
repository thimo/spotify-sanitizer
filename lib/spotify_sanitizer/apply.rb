# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module SpotifySanitizer
  # Executes a reviewed plan against the Spotify library, and writes a reversal
  # log so any run can be undone.
  #
  # Reversal semantics: unliking a track is reversible (re-like it); re-liking
  # is reversible (unlike it). The log records exactly what we changed.
  class Apply
    def initialize(client = Client.new, log_dir: File.join(Config.home, "logs"))
      @client = client
      @log_dir = log_dir
      FileUtils.mkdir_p(@log_dir)
    end

    def run(plan_hash, dry_run: false)
      remove_ids = Array(plan_hash["removals"]).map { |r| r["id"] }.compact
      add_ids    = Array(plan_hash["additions"]).map { |a| a["id"] }.compact

      if dry_run
        puts "DRY RUN — would unlike #{remove_ids.size}, like #{add_ids.size}. Nothing changed."
        return
      end

      @client.delete("/me/tracks", remove_ids) unless remove_ids.empty?
      @client.put("/me/tracks", add_ids)       unless add_ids.empty?

      log = write_log(remove_ids, add_ids)
      puts "Applied: unliked #{remove_ids.size}, liked #{add_ids.size}."
      puts "Reversal log: #{log}"
      puts "Undo with: spotify-sanitizer undo #{log}"
    end

    # Inverts a reversal log: re-like what we removed, unlike what we added.
    def undo(log_path)
      log = JSON.parse(File.read(log_path))
      @client.put("/me/tracks", log["removed"]) unless log["removed"].to_a.empty?
      @client.delete("/me/tracks", log["added"]) unless log["added"].to_a.empty?
      puts "Undone: re-liked #{log["removed"].to_a.size}, unliked #{log["added"].to_a.size}."
    end

    private

    def write_log(removed, added)
      path = File.join(@log_dir, "apply-#{Time.now.strftime("%Y%m%d-%H%M%S")}.json")
      File.write(path, JSON.pretty_generate(
        "applied_at" => Time.now.iso8601,
        "removed"    => removed,
        "added"      => added
      ))
      path
    end
  end
end
