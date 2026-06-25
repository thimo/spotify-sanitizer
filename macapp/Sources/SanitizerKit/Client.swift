import Foundation

enum ApiError: Error, LocalizedError {
    case unauthorized
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized:        return "Unauthorized (401). Token may be revoked — log in again."
        case .http(let c, let p):  return "Spotify API error \(c) on \(p)"
        case .badResponse:         return "Unexpected response from Spotify."
        }
    }
}

// Thin Spotify Web API client over URLSession: bearer auth, JSON, 429 backoff,
// cursor pagination, and 50-id batched library writes. Ported from client.rb.
struct Client {
    static let base = "https://api.spotify.com/v1"

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
    func eachPage(_ path: String, _ params: [String: String] = [:], key: String? = nil) async throws -> [[String: Any]] {
        var url = buildURL(path, params.merging(["limit": "50"]) { _, new in new })
        var items: [[String: Any]] = []
        while true {
            var page = try await request("GET", url: url)
            if let key, let nested = page[key] as? [String: Any] { page = nested }
            items.append(contentsOf: (page["items"] as? [[String: Any]]) ?? [])
            guard let next = page["next"] as? String, !next.isEmpty, let nextURL = URL(string: next) else { break }
            url = nextURL
        }
        return items
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
            if data.isEmpty { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        case 429:
            let wait = (Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1) + 1
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            return try await request(method, url: url, body: body)
        case 401:
            throw ApiError.unauthorized
        default:
            let payload = String(data: data, encoding: .utf8) ?? ""
            throw ApiError.http(http.statusCode, "\(url.path) \(payload)")
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
