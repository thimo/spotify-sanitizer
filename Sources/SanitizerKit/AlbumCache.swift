import Foundation

// Album tracklists never change, so cache the raw /albums/{id}/tracks payload
// on disk. Re-scans then skip the per-album fetches entirely — the biggest
// chunk of a scan's requests — which is what trips Spotify's daily dev limit.
enum AlbumCache {
    private static var dir: URL {
        let d = Config.home.appendingPathComponent("album-cache")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func url(_ albumID: String) -> URL {
        dir.appendingPathComponent("\(albumID).json")   // album ids are base62 — filename-safe
    }

    static func load(_ albumID: String) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: url(albumID)),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return items
    }

    static func save(_ albumID: String, _ items: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return }
        try? data.write(to: url(albumID))
    }
}
