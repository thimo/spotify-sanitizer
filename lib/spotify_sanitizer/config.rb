# frozen_string_literal: true

require "json"
require "fileutils"

module SpotifySanitizer
  # Locates and reads/writes the on-disk config + token cache.
  #
  # Layout (XDG-style, override the root with SPOTIFY_SANITIZER_HOME):
  #   ~/.config/spotify-sanitizer/config.json   client_id, redirect_uri
  #   ~/.config/spotify-sanitizer/tokens.json   access/refresh tokens (chmod 600)
  module Config
    module_function

    # Spotify only needs a Client ID for the PKCE flow (no secret), so the app
    # can ship without embedding any credential. The user registers a free app
    # at https://developer.spotify.com and drops the ID into config.json.
    DEFAULT_REDIRECT_URI = "http://127.0.0.1:8888/callback"
    # user-read-private lets the search endpoint resolve `market=from_token`,
    # which the optional `--find-alternatives` scan needs.
    SCOPES = %w[user-library-read user-library-modify user-read-private].freeze

    def home
      base = ENV["SPOTIFY_SANITIZER_HOME"] ||
             File.join(ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config"),
                       "spotify-sanitizer")
      FileUtils.mkdir_p(base)
      base
    end

    def config_path = File.join(home, "config.json")
    def tokens_path = File.join(home, "tokens.json")

    def load
      return {} unless File.exist?(config_path)

      JSON.parse(File.read(config_path))
    end

    def client_id
      id = ENV["SPOTIFY_CLIENT_ID"] || load["client_id"]
      return id if id && !id.empty?

      raise ConfigError, <<~MSG
        No Spotify Client ID found.

        1. Create a free app at https://developer.spotify.com/dashboard
        2. Add this Redirect URI to the app settings:
             #{redirect_uri}
        3. Save the Client ID with:
             spotify-sanitizer login --client-id=YOUR_ID
           (or export SPOTIFY_CLIENT_ID, or edit #{config_path})
      MSG
    end

    def redirect_uri
      load["redirect_uri"] || DEFAULT_REDIRECT_URI
    end

    def save_config(values)
      merged = load.merge(values.transform_keys(&:to_s))
      File.write(config_path, JSON.pretty_generate(merged))
      merged
    end

    def load_tokens
      return nil unless File.exist?(tokens_path)

      JSON.parse(File.read(tokens_path))
    end

    def save_tokens(tokens)
      File.write(tokens_path, JSON.pretty_generate(tokens))
      File.chmod(0o600, tokens_path)
      tokens
    end

    class ConfigError < StandardError; end
  end
end
