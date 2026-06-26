import Foundation

// Tiny NSRegularExpression conveniences (compiled once).
private func regex(_ pattern: String) -> NSRegularExpression {
    // Patterns here are static and valid; force-try is fine.
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

private extension String {
    func matches(_ re: NSRegularExpression) -> Bool {
        re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }
    func replacingFirst(_ re: NSRegularExpression, with replacement: String) -> String {
        guard let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let r = Range(m.range, in: self) else { return self }
        return replacingCharacters(in: r, with: replacement)
    }
    func replacingAll(_ re: NSRegularExpression, with replacement: String) -> String {
        re.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: replacement)
    }
}

// A liked track flattened from the Spotify "saved track" object into just the
// fields the analyzer reasons about — ported from the Ruby Track class, plus an
// artwork URL and an open-in-Spotify link for the UI.
struct Track {
    let id: String?
    let name: String
    let artists: [String]
    let albumID: String?
    let albumName: String
    let albumType: String?
    let albumTotalTracks: Int
    let durationMs: Int
    let explicit: Bool
    let isrc: String?
    let playable: Bool
    let addedAt: String?
    let uri: String?
    let imageURL: String?
    let spotifyURL: String?

    init(_ saved: [String: Any]) {
        let t = (saved["track"] as? [String: Any]) ?? saved
        let album = (t["album"] as? [String: Any]) ?? [:]

        id = t["id"] as? String
        name = (t["name"] as? String) ?? ""
        artists = ((t["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        albumID = album["id"] as? String
        albumName = (album["name"] as? String) ?? ""
        albumType = album["album_type"] as? String
        albumTotalTracks = (album["total_tracks"] as? Int) ?? 0
        durationMs = (t["duration_ms"] as? Int) ?? 0
        explicit = (t["explicit"] as? Bool) ?? false
        isrc = (t["external_ids"] as? [String: Any])?["isrc"] as? String
        // is_playable only appears when a market is supplied; treat missing as playable.
        playable = (t["is_playable"] as? Bool) ?? true
        addedAt = saved["added_at"] as? String
        uri = t["uri"] as? String

        imageURL = Track.pickImage(album["images"] as? [[String: Any]])
        if let url = (t["external_urls"] as? [String: Any])?["spotify"] as? String {
            spotifyURL = url
        } else if let id = t["id"] as? String {
            spotifyURL = "https://open.spotify.com/track/\(id)"
        } else {
            spotifyURL = nil
        }
    }

    var primaryArtist: String { artists.first ?? "" }
    var durationSeconds: Int { durationMs / 1000 }

    // Prefer an image near 300px (crisp list thumbnail), else the first one.
    static func pickImage(_ images: [[String: Any]]?) -> String? {
        guard let images, !images.isEmpty else { return nil }
        let best = images.min { a, b in
            let wa = abs(((a["width"] as? Int) ?? 0) - 300)
            let wb = abs(((b["width"] as? Int) ?? 0) - 300)
            return wa < wb
        }
        return (best ?? images.first)?["url"] as? String
    }

    // MARK: - Heuristics (mirrors Ruby Track)

    private static let skitPattern = regex(#"\b(skit|interlude|intro|outro|prelude|reprise|segue)\b"#)
    private static let versionCruft = regex(#"\s*[-(\[].*?(remaster|remastered|mono|stereo|deluxe|edit|version|anniversary|mix|live|radio).*?[)\]]?$"#)
    private static let nonAlnum = regex(#"[^a-z0-9]+"#)

    func isSkit(maxSeconds: Int = 60) -> Bool {
        durationMs <= maxSeconds * 1000 || name.matches(Track.skitPattern)
    }

    // Normalized key for fuzzy "same song, different release" clustering.
    var fuzzyKey: String {
        var title = name.lowercased()
        title = title.replacingFirst(Track.versionCruft, with: "")
        title = title.replacingAll(Track.nonAlnum, with: " ").trimmingCharacters(in: .whitespaces)
        let artist = primaryArtist.lowercased()
            .replacingAll(Track.nonAlnum, with: " ").trimmingCharacters(in: .whitespaces)
        let bucket = Int((Double(durationMs) / 5000.0).rounded())
        return "\(artist)|\(title)|\(bucket)"
    }

    // Display card for the UI / plan serialization.
    var card: Card {
        Card(id: id ?? UUID().uuidString,
             artist: primaryArtist,
             title: name,
             album: albumName,
             explicit: explicit,
             durationMs: durationMs,
             image: imageURL,
             url: spotifyURL,
             uri: uri ?? id.map { "spotify:track:\($0)" })
    }
}
