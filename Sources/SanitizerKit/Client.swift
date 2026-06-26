import Foundation

public enum ApiError: Error, LocalizedError {
    case unauthorized
    case http(Int, String)
    case badResponse
    case rateLimited(Int)   // Retry-After seconds

    public var errorDescription: String? {
        switch self {
        case .unauthorized:        return "Unauthorized (401). Token may be revoked — log in again."
        case .http(let c, let p):  return "Spotify API error \(c) on \(p)"
        case .badResponse:         return "Unexpected response from Spotify."
        case .rateLimited(let s):  return "Spotify rate limit hit — try again in about \(Self.humanize(s)). It clears on its own."
        }
    }

    static func humanize(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60) min" }
        return "\(seconds)s"
    }
}

// Thin Spotify Web API client over URLSession: bearer auth, JSON, 429 backoff,
// cursor pagination, and 50-id batched library writes. Ported from client.rb.
struct Client {
    static let base = "https://api.spotify.com/v1"
    // Honour short 429 cool-downs inline; fail fast on anything longer.
    static let maxAutoRetryWait = 90

    func get(_ path: String, _ params: [String: String] = [:]) async throws -> [String: Any] {
        try await request("GET", url: buildURL(path, params))
    }

    // Library-modify endpoints take up to 50 ids per call.
    func put(_ path: String, ids: [String]) async throws {
        for slice in ids.chunked(50) {
            _ = try await request("PUT", url: buildURL(path), body: ["ids": slice])
        }
    }

    func delete(_ path: String, ids: [String]) async throws {
        for slice in ids.chunked(50) {
            _ = try await request("DELETE", url: buildURL(path), body: ["ids": slice])
        }
    }

    // Walk a paginated endpoint, collecting every item. Spotify returns either a
    // top-level paging object or one nested under a key (e.g. "albums").
    func eachPage(_ path: String, _ params: [String: String] = [:], key: String? = nil,
                  onProgress: ((Int) -> Void)? = nil) async throws -> [[String: Any]] {
        var url = buildURL(path, params.merging(["limit": "50"]) { _, new in new })
        var items: [[String: Any]] = []
        while true {
            var page = try await request("GET", url: url)
            if let key, let nested = page[key] as? [String: Any] { page = nested }
            items.append(contentsOf: (page["items"] as? [[String: Any]]) ?? [])
            onProgress?(items.count)
            guard let next = page["next"] as? String, !next.isEmpty, let nextURL = URL(string: next) else { break }
            url = nextURL
        }
        return items
    }

    // Offset-paginated fetch: read page 0 to learn `total`, then fetch the rest
    // concurrently (bounded) instead of chasing `next` cursors one by one.
    // Returns items in order. Reports (done, total) so callers show a real bar.
    func pagedConcurrent(_ path: String, _ params: [String: String] = [:],
                         pageSize: Int = 50, concurrency: Int = 5,
                         onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil) async throws -> [[String: Any]] {
        func page(_ offset: Int) async throws -> (items: [[String: Any]], total: Int) {
            let merged = params.merging(["limit": "\(pageSize)", "offset": "\(offset)"]) { _, new in new }
            let json = try await request("GET", url: buildURL(path, merged))
            let items = (json["items"] as? [[String: Any]]) ?? []
            return (items, (json["total"] as? Int) ?? items.count)
        }

        let first = try await page(0)
        onProgress?(first.items.count, first.total)
        if first.total <= pageSize { return first.items }

        let offsets = Array(stride(from: pageSize, to: first.total, by: pageSize))
        let rest = try await boundedMap(offsets, limit: concurrency, onProgress: { done in
            onProgress?(min(first.items.count + done * pageSize, first.total), first.total)
        }) { offset in
            try await page(offset).items
        }
        return first.items + rest.flatMap { $0 }
    }

    // MARK: - internals

    private func buildURL(_ path: String, _ params: [String: String] = [:]) -> URL {
        var comps = URLComponents(string: path.hasPrefix("http") ? path : "\(Client.base)\(path)")!
        if !params.isEmpty {
            comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    private func request(_ method: String, url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = try await Auth.accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ApiError.badResponse }

        switch http.statusCode {
        case 200..<300:
            RateLimit.clearIfPresent()   // a success means the cooldown is over
            if data.isEmpty { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        case 429:
            let retryAfter = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
            Log.net("429 on \(url.path); Retry-After \(retryAfter)s")
            // Auto-retry only short cool-downs; don't hang for minutes/hours.
            guard retryAfter <= Client.maxAutoRetryWait else {
                RateLimit.record(retryAfter: retryAfter)
                throw ApiError.rateLimited(retryAfter)
            }
            try await Task.sleep(nanoseconds: UInt64(retryAfter + 1) * 1_000_000_000)
            return try await request(method, url: url, body: body)
        case 401:
            throw ApiError.unauthorized
        default:
            let payload = String(data: data, encoding: .utf8) ?? ""
            Log.net("error \(http.statusCode) on \(url.path): \(payload.prefix(200))")
            throw ApiError.http(http.statusCode, "\(url.path) \(payload)")
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
