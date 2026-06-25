# frozen_string_literal: true

require "optparse"
require "fileutils"

module SpotifySanitizer
  # Command-line entry point. Subcommands: login, scan, apply, undo, status.
  class CLI
    def self.start(argv) = new.run(argv)

    def run(argv)
      command = argv.shift || "help"
      case command
      when "login"           then cmd_login(argv)
      when "scan"            then cmd_scan(argv)
      when "apply"           then cmd_apply(argv)
      when "undo"            then cmd_undo(argv)
      when "status"          then cmd_status(argv)
      when "version", "-v", "--version" then puts "spotify-sanitizer #{VERSION}"
      when "help", "-h", "--help" then puts help
      else
        warn "Unknown command: #{command}\n\n#{help}"
        exit 1
      end
    rescue Config::ConfigError, Auth::NotLoggedIn, Auth::AuthError, Client::ApiError => e
      warn "Error: #{e.message}"
      exit 1
    rescue Interrupt
      warn "\nAborted."
      exit 130
    end

    private

    def cmd_login(argv)
      OptionParser.new do |o|
        o.banner = "Usage: spotify-sanitizer login [--client-id=ID]"
        o.on("--client-id=ID", "Save your Spotify app Client ID") do |id|
          Config.save_config(client_id: id)
          puts "Saved Client ID to #{Config.config_path}"
        end
      end.parse!(argv)

      Config.client_id # raises with setup instructions if still unset
      Auth.login!
      puts "Logged in. Tokens cached at #{Config.tokens_path}"
    end

    def cmd_scan(argv)
      opts = { out: nil, market: nil }
      analyzer_opts = {}
      OptionParser.new do |o|
        o.banner = "Usage: spotify-sanitizer scan [options]"
        o.on("--threshold=N", Float, "Album-completion threshold 0..1 (default 0.70)") { |v| analyzer_opts[:completion_threshold] = v }
        o.on("--skit-seconds=N", Integer, "Tracks <= N seconds count as skits (default 60)") { |v| analyzer_opts[:skit_max_seconds] = v }
        o.on("--[no-]complete-albums", "Suggest completing partial albums (default on)") { |v| analyzer_opts[:complete_albums] = v }
        o.on("--[no-]drop-unplayable", "Remove unplayable tracks (default on)") { |v| analyzer_opts[:drop_unplayable] = v }
        o.on("--find-alternatives", "For unplayable tracks, find the same recording (ISRC) on a playable release") { analyzer_opts[:find_alternatives] = true }
        o.on("--market=CC", "Market for playability/search, e.g. NL (default: from your token)") { |v| opts[:market] = v }
        o.on("--out=DIR", "Where to write the plan (default ./plans)") { |v| opts[:out] = v }
      end.parse!(argv)

      client  = Client.new
      library = opts[:market] ? Library.new(client, market: opts[:market]) : Library.new(client)

      print "Fetching your liked songs… "
      tracks = library.liked_tracks
      puts "#{tracks.size} tracks."

      print "Analyzing… "
      plan = Analyzer.new(tracks, library: library, options: analyzer_opts).build_plan
      puts "done."

      dir = opts[:out] || File.join(Dir.pwd, "plans")
      FileUtils.mkdir_p(dir)
      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      json = plan.save_json(File.join(dir, "#{stamp}.plan.json"))
      txt  = File.join(dir, "#{stamp}.plan.txt")
      File.write(txt, plan.to_text)

      puts
      puts plan.to_text
      puts
      puts "Plan written to:"
      puts "  #{json}"
      puts "  #{txt}"
      puts
      if plan.empty?
        puts "Nothing to do — your library is already spotless. Monk would approve."
      else
        puts "Review it, then: spotify-sanitizer apply #{json}"
      end
    end

    def cmd_apply(argv)
      dry = false
      yes = false
      OptionParser.new do |o|
        o.banner = "Usage: spotify-sanitizer apply <plan.json> [--dry-run] [--yes]"
        o.on("--dry-run", "Show what would change without doing it") { dry = true }
        o.on("--yes", "-y", "Skip the confirmation prompt") { yes = true }
      end.parse!(argv)

      path = argv.shift or abort "Usage: spotify-sanitizer apply <plan.json>"
      plan = Plan.load_json(path)
      replacements = plan["replacements"].to_a.size
      removals = plan["removals"].to_a.size + replacements
      additions = plan["additions"].to_a.size + replacements

      puts "Plan: unlike #{removals}, like #{additions} (incl. #{replacements} replacement(s))."
      unless dry || yes
        print "Apply these changes to your Spotify library? [y/N] "
        abort "Aborted." unless $stdin.gets.to_s.strip.downcase.start_with?("y")
      end

      Apply.new.run(plan, dry_run: dry)
    end

    def cmd_undo(argv)
      path = argv.shift or abort "Usage: spotify-sanitizer undo <apply-log.json>"
      Apply.new.undo(path)
    end

    def cmd_status(_argv)
      puts "Config dir:  #{Config.home}"
      puts "Client ID:   #{Config.load["client_id"] ? "set" : "not set"}"
      puts "Logged in:   #{Auth.logged_in? ? "yes" : "no"}"
    end

    def help
      <<~HELP
        spotify-sanitizer #{VERSION} — obsessively tidy your Spotify library

        Usage:
          spotify-sanitizer login [--client-id=ID]   Authorize with Spotify
          spotify-sanitizer scan [options]           Build a reviewable cleanup plan (read-only)
          spotify-sanitizer apply <plan.json>        Execute a reviewed plan
          spotify-sanitizer undo <apply-log.json>    Revert an applied plan
          spotify-sanitizer status                   Show config / auth state

        scan options:
          --threshold=N           Album-completion threshold 0..1 (default 0.70)
          --skit-seconds=N        Tracks <= N seconds count as skits (default 60)
          --no-complete-albums    Don't suggest completing partial albums
          --no-drop-unplayable    Keep unplayable/greyed-out tracks
          --find-alternatives     Replace unplayable tracks with the same recording (ISRC) from a playable release
          --market=CC             Market for playability/search, e.g. NL (default: from your token)
          --out=DIR               Where to write the plan (default ./plans)

        scan never changes anything. apply does, and writes a reversal log.
      HELP
    end
  end
end
