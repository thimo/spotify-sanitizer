# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "securerandom"
require "digest"
require "base64"
require "socket"

module SpotifySanitizer
  # OAuth 2.0 Authorization Code flow with PKCE.
  #
  # No client secret is used (PKCE), so this is safe to run as a local CLI:
  # we spin up a one-shot loopback HTTP server to catch the redirect, exchange
  # the code for tokens, and cache them. `access_token` transparently refreshes.
  module Auth
    AUTHORIZE_URL = "https://accounts.spotify.com/authorize"
    TOKEN_URL     = "https://accounts.spotify.com/api/token"

    module_function

    # Returns a valid access token, running the interactive login or a silent
    # refresh as needed.
    def access_token
      tokens = Config.load_tokens
      raise NotLoggedIn, "Not logged in. Run: spotify-sanitizer login" unless tokens

      tokens = refresh(tokens) if expired?(tokens)
      tokens["access_token"]
    end

    def logged_in?
      !Config.load_tokens.nil?
    end

    def expired?(tokens)
      # Refresh a minute early to avoid races on long scans.
      Time.now.to_i >= (tokens["expires_at"].to_i - 60)
    end

    # Interactive browser login. Returns the token hash.
    def login!
      verifier  = SecureRandom.urlsafe_base64(64).tr("=", "")
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier)).tr("=", "")
      state     = SecureRandom.hex(16)
      redirect  = URI(Config.redirect_uri)

      params = {
        client_id:             Config.client_id,
        response_type:         "code",
        redirect_uri:          Config.redirect_uri,
        scope:                 Config::SCOPES.join(" "),
        code_challenge_method: "S256",
        code_challenge:        challenge,
        state:                 state
      }
      url = "#{AUTHORIZE_URL}?#{URI.encode_www_form(params)}"

      puts "Opening your browser to authorize spotify-sanitizer…"
      puts "If it doesn't open, paste this URL:\n\n#{url}\n\n"
      open_browser(url)

      code = await_redirect(redirect.port, redirect.path, expected_state: state)
      tokens = exchange_code(code, verifier)
      Config.save_tokens(tokens)
      tokens
    end

    # --- internals -----------------------------------------------------------

    def exchange_code(code, verifier)
      body = {
        grant_type:    "authorization_code",
        code:          code,
        redirect_uri:  Config.redirect_uri,
        client_id:     Config.client_id,
        code_verifier: verifier
      }
      store(post_token(body))
    end

    def refresh(tokens)
      body = {
        grant_type:    "refresh_token",
        refresh_token: tokens["refresh_token"],
        client_id:     Config.client_id
      }
      fresh = post_token(body)
      # Spotify may omit a new refresh_token; keep the old one if so.
      fresh["refresh_token"] ||= tokens["refresh_token"]
      store(fresh)
    end

    def post_token(body)
      res = Net::HTTP.post_form(URI(TOKEN_URL), body)
      data = JSON.parse(res.body)
      unless res.is_a?(Net::HTTPSuccess)
        raise AuthError, "Token request failed (#{res.code}): #{data["error_description"] || data["error"] || res.body}"
      end

      data
    end

    def store(data)
      data["expires_at"] = Time.now.to_i + data.fetch("expires_in", 3600).to_i
      Config.save_tokens(data)
    end

    # One-shot loopback server that captures ?code=…&state=… from the redirect.
    def await_redirect(port, path, expected_state:)
      server = TCPServer.new("127.0.0.1", port)
      loop do
        socket = server.accept
        request_line = socket.gets.to_s
        # Drain the rest of the request headers up to the blank line so the
        # browser gets a clean response. Read one line at a time and stop at the
        # CRLF; never call eof?, which blocks while the browser holds the
        # connection open waiting for our reply.
        while (line = socket.gets) && !line.strip.empty?; end

        unless request_line.start_with?("GET #{path}")
          respond(socket, 404, "Not found")
          socket.close
          next
        end

        query = request_line.split(" ")[1].to_s.split("?", 2)[1].to_s
        params = URI.decode_www_form(query).to_h

        if params["error"]
          respond(socket, 400, "Authorization denied: #{params["error"]}. You can close this tab.")
          socket.close
          raise AuthError, "Authorization denied: #{params["error"]}"
        end

        if params["state"] != expected_state
          respond(socket, 400, "State mismatch — possible CSRF. You can close this tab.")
          socket.close
          raise AuthError, "OAuth state mismatch"
        end

        respond(socket, 200, "spotify-sanitizer is authorized. You can close this tab and return to the terminal.")
        socket.close
        return params["code"]
      end
    ensure
      server&.close
    end

    def respond(socket, status, message)
      text = "<!doctype html><meta charset=utf-8><title>spotify-sanitizer</title>" \
             "<body style='font:16px system-ui;margin:3rem'>#{message}</body>"
      socket.print "HTTP/1.1 #{status} OK\r\n"
      socket.print "Content-Type: text/html; charset=utf-8\r\n"
      socket.print "Content-Length: #{text.bytesize}\r\n"
      socket.print "Connection: close\r\n\r\n"
      socket.print text
    end

    def open_browser(url)
      cmd =
        case RbConfig::CONFIG["host_os"]
        when /darwin/      then ["open", url]
        when /mswin|mingw/ then ["cmd", "/c", "start", url]
        else                    ["xdg-open", url]
        end
      system(*cmd, out: File::NULL, err: File::NULL)
    end

    class NotLoggedIn < StandardError; end
    class AuthError < StandardError; end
  end
end
