# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module SpotifySanitizer
  # Thin Spotify Web API client over net/http. Handles bearer auth, JSON,
  # 429 rate-limit backoff, and cursor pagination.
  class Client
    BASE = "https://api.spotify.com/v1"

    def initialize(token: nil)
      @token = token || Auth.access_token
    end

    def get(path, params = {})
      request(Net::HTTP::Get, build_uri(path, params))
    end

    # Spotify's library-modify endpoints take up to 50 ids per call.
    def put(path, ids)
      ids.each_slice(50) { |slice| request(Net::HTTP::Put, build_uri(path), body: { ids: slice }) }
    end

    def delete(path, ids)
      ids.each_slice(50) { |slice| request(Net::HTTP::Delete, build_uri(path), body: { ids: slice }) }
    end

    # Walks a paginated endpoint, yielding each item. Spotify returns either a
    # top-level paging object or one nested under a key (e.g. "albums").
    def each_page(path, params = {}, key: nil)
      url = build_uri(path, params.merge(limit: 50))
      loop do
        page = request(Net::HTTP::Get, url)
        page = page[key] if key
        page["items"].each { |item| yield item }
        next_url = page["next"]
        break unless next_url

        url = URI(next_url)
      end
    end

    private

    def build_uri(path, params = {})
      uri = URI(path.start_with?("http") ? path : "#{BASE}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?
      uri
    end

    def request(klass, uri, body: nil)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      req = klass.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      res = http.request(req)

      case res
      when Net::HTTPSuccess
        res.body.to_s.empty? ? {} : JSON.parse(res.body)
      when Net::HTTPTooManyRequests
        wait = res["retry-after"].to_i + 1
        warn "Rate limited; waiting #{wait}s…"
        sleep(wait)
        request(klass, uri, body: body)
      when Net::HTTPUnauthorized
        raise ApiError, "Unauthorized (401). Token may be revoked — run: spotify-sanitizer login"
      else
        raise ApiError, "API error #{res.code} on #{uri.path}: #{res.body}"
      end
    end

    class ApiError < StandardError; end
  end
end
