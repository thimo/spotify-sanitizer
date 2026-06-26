import Foundation

// Display/serialization record for one track in the plan.
public struct Card: Codable, Hashable {
    public var id: String
    public var artist: String
    public var title: String
    public var album: String
    public var explicit: Bool
    public var durationMs: Int
    public var image: String?
    public var url: String?        // open.spotify.com web link (fallback)
    public var uri: String?        // spotify:track:… — opens the desktop app

    public var durationSeconds: Int { durationMs / 1000 }

    // Spotify-style M:SS (or H:MM:SS for the rare hour-plus track).
    public var durationFormatted: String {
        let s = durationMs / 1000
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// The reviewable output of a scan: what would be unliked, replaced, and liked,
// each with a human-readable reason. Mirrors the Ruby Plan, plus structured
// cards (artwork + links) for the UI. Building a Plan never mutates Spotify.
public struct Plan: Codable {
    public struct Removal: Codable, Identifiable {
        public let id = UUID()
        public var card: Card
        public var reason: String
        public var keeper: Card?
        private enum CodingKeys: String, CodingKey { case card, reason, keeper }
    }
    public struct Replacement: Codable, Identifiable {
        public let id = UUID()
        public var dead: Card
        public var alternative: Card
        public var reason: String
        private enum CodingKeys: String, CodingKey { case dead, alternative, reason }
    }
    // One track in an album's full tracklist; `liked` means it's already in your
    // library (context), otherwise it's a proposed addition (tickable).
    public struct AlbumTrack: Codable, Identifiable {
        public let id = UUID()
        public var card: Card
        public var liked: Bool
        private enum CodingKeys: String, CodingKey { case card, liked }
    }
    // A partially-liked album: its full (non-skit) tracklist, in order.
    public struct AlbumCompletion: Codable, Identifiable {
        public let id = UUID()
        public var album: String
        public var likedCount: Int
        public var total: Int
        public var tracks: [AlbumTrack]
        private enum CodingKeys: String, CodingKey { case album, likedCount, total, tracks }

        public var missing: [AlbumTrack] { tracks.filter { !$0.liked } }
    }

    public var removals: [Removal] = []
    public var replacements: [Replacement] = []
    public var completions: [AlbumCompletion] = []
    public var stats: [String: Int] = [:]

    public init() {}

    public var additionsCount: Int { completions.reduce(0) { $0 + $1.missing.count } }
    public var isEmpty: Bool { removals.isEmpty && replacements.isEmpty && completions.isEmpty }

    mutating func remove(_ track: Track, reason: String, keeper: Track? = nil) {
        removals.append(Removal(card: track.card, reason: reason, keeper: keeper?.card))
    }
    mutating func replace(_ dead: Track, with alternative: Track, reason: String) {
        replacements.append(Replacement(dead: dead.card, alternative: alternative.card, reason: reason))
    }
    // `tracks` is the full non-skit album tracklist in order; `likedIDs` flags
    // which are already in the library.
    mutating func addCompletion(album: String, tracks: [Track], likedIDs: Set<String>) {
        let entries = tracks.map { track in
            AlbumTrack(card: track.card, liked: track.id.map { likedIDs.contains($0) } ?? false)
        }
        completions.append(AlbumCompletion(album: album,
                                           likedCount: entries.filter { $0.liked }.count,
                                           total: entries.count,
                                           tracks: entries))
    }
}
