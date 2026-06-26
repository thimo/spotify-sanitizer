import Foundation

// What the analyzer needs from a library — extracted so tests can stub it.
protocol LibraryProviding {
    func albumTracks(_ albumID: String, albumName: String?, albumImage: String?) async throws -> [Track]
    func findAlternative(_ track: Track) async throws -> Track?
}

// Reads the user's saved tracks + album tracklists, and searches for ISRC
// alternatives. Ported from library.rb.
struct Library: LibraryProviding {
    var client: Client
    var market: String = "from_token"

    func likedTracks(onProgress: ((Int) -> Void)? = nil) async throws -> [Track] {
        try await client.eachPage("/me/tracks", ["market": market], onProgress: onProgress).map { Track($0) }
    }

    func albumTracks(_ albumID: String, albumName: String?, albumImage: String? = nil) async throws -> [Track] {
        let items = try await client.eachPage("/albums/\(albumID)/tracks", ["market": market])
        return items.map { item in
            // /albums/{id}/tracks items are bare track objects; graft a minimal
            // album block (name + cover) back on so Track can describe itself.
            var merged = item
            var album: [String: Any] = ["id": albumID]
            if let albumName { album["name"] = albumName }
            if let albumImage { album["images"] = [["url": albumImage]] }
            merged["album"] = album
            return Track(merged)
        }
    }

    // Spotify's search rejects limit > 10 (despite docs); an ISRC has few
    // releases so 10 is plenty.
    static let searchLimit = 10
    static let durationToleranceMs = 3000

    // A playable stand-in for an unplayable track: the same recording (same
    // ISRC and length, to dodge recycled/bootleg ISRCs) on a release that
    // plays in the market.
    func findAlternative(_ track: Track) async throws -> Track? {
        guard let isrc = track.isrc, !isrc.isEmpty else { return nil }
        return try await searchTracks("isrc:\(isrc)").first { candidate in
            candidate.playable
                && candidate.id != track.id
                && abs(candidate.durationMs - track.durationMs) <= Library.durationToleranceMs
        }
    }

    private func searchTracks(_ query: String) async throws -> [Track] {
        let res = try await client.get("/search", [
            "q": query, "type": "track", "market": market, "limit": "\(Library.searchLimit)"
        ])
        let items = (res["tracks"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.map { Track($0) }
    }
}
