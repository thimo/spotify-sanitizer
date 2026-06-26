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
    public struct Addition: Codable, Identifiable {
        public let id = UUID()
        public var card: Card
        public var reason: String
        private enum CodingKeys: String, CodingKey { case card, reason }
    }
    public struct Replacement: Codable, Identifiable {
        public let id = UUID()
        public var dead: Card
        public var alternative: Card
        public var reason: String
        private enum CodingKeys: String, CodingKey { case dead, alternative, reason }
    }

    public var removals: [Removal] = []
    public var additions: [Addition] = []
    public var replacements: [Replacement] = []
    public var stats: [String: Int] = [:]

    public init() {}

    public var isEmpty: Bool { removals.isEmpty && additions.isEmpty && replacements.isEmpty }

    mutating func remove(_ track: Track, reason: String, keeper: Track? = nil) {
        removals.append(Removal(card: track.card, reason: reason, keeper: keeper?.card))
    }
    mutating func add(_ track: Track, reason: String) {
        additions.append(Addition(card: track.card, reason: reason))
    }
    mutating func replace(_ dead: Track, with alternative: Track, reason: String) {
        replacements.append(Replacement(dead: dead.card, alternative: alternative.card, reason: reason))
    }
}
