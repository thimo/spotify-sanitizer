import Foundation

// What the analyzer needs from a library — extracted so tests can stub it.
protocol LibraryProviding {
    func albumTracks(_ albumID: String, albumName: String?, albumImage: String?) async throws -> [Track]
    func findAlternative(_ track: Track, fuzzy: Bool) async throws -> (track: Track, fuzzy: Bool)?
}

// Reads the user's saved tracks + album tracklists, and searches for ISRC
// alternatives. Ported from library.rb.
struct Library: LibraryProviding {
    var client: Client
    var market: String = "from_token"

    func likedTracks(onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil) async throws -> [Track] {
        // One cheap probe (total + most-recent id). If both match the cache, the
        // library is unchanged since last scan — reuse it instead of refetching
        // ~67 pages. New likes land first (id changes); unlikes change total.
        let probe = try await client.get("/me/tracks", ["market": market, "limit": "1"])
        let total = (probe["total"] as? Int) ?? -1
        let firstID = ((probe["items"] as? [[String: Any]])?.first?["track"] as? [String: Any])?["id"] as? String

        let items: [[String: Any]]
        if let cached = LibraryCache.load(), cached.total == total, cached.firstID == firstID {
            Log.scan("library unchanged — reusing cache (\(cached.items.count) tracks)")
            onProgress?(cached.items.count, cached.items.count)
            items = cached.items
        } else {
            items = try await client.pagedConcurrent("/me/tracks", ["market": market], onProgress: onProgress)
            LibraryCache.save(total: total, firstID: firstID, items: items)
        }

        let tracks = items.map { Track($0) }
        // Local files / null-track items have no usable id and can't be acted on
        // by the API; drop them so apply never targets a fabricated id.
        let actionable = tracks.filter { $0.id != nil }
        let skipped = tracks.count - actionable.count
        if skipped > 0 { Log.scan("skipped \(skipped) local/unidentifiable liked track(s)") }
        return actionable
    }

    func albumTracks(_ albumID: String, albumName: String?, albumImage: String? = nil) async throws -> [Track] {
        let items: [[String: Any]]
        if let cached = AlbumCache.load(albumID) {
            items = cached
        } else {
            items = try await client.eachPage("/albums/\(albumID)/tracks", ["market": market])
            AlbumCache.save(albumID, items)
        }
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

    // A playable stand-in for an unplayable track. First the *same recording*
    // (same ISRC and length, to dodge recycled/bootleg ISRCs). If `fuzzy` is on
    // and that misses, fall back to a title+artist search (same fuzzyKey) — that
    // may be a different version, so it's flagged for the user to verify.
    func findAlternative(_ track: Track, fuzzy: Bool) async throws -> (track: Track, fuzzy: Bool)? {
        if let isrc = track.isrc, !isrc.isEmpty {
            if let exact = try await searchTracks("isrc:\(isrc)").first(where: { matches($0, track) }) {
                return (exact, false)
            }
        }
        guard fuzzy else { return nil }
        let query = "track:\(track.name) artist:\(track.primaryArtist)"
        if let alt = try await searchTracks(query).first(where: { matches($0, track) && $0.fuzzyKey == track.fuzzyKey }) {
            return (alt, true)
        }
        return nil
    }

    private func matches(_ candidate: Track, _ original: Track) -> Bool {
        candidate.playable
            && candidate.id != original.id
            && abs(candidate.durationMs - original.durationMs) <= Library.durationToleranceMs
    }

    private func searchTracks(_ query: String) async throws -> [Track] {
        let res = try await client.get("/search", [
            "q": query, "type": "track", "market": market, "limit": "\(Library.searchLimit)"
        ])
        let items = (res["tracks"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.map { Track($0) }
    }
}
