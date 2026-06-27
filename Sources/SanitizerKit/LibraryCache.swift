import Foundation

// Caches the full liked-songs payload so an unchanged library doesn't get
// refetched page by page. Keyed by (total, most-recent track id): a new like
// changes the first id, an unlike changes the total — so a match means nothing
// changed since last scan.
enum LibraryCache {
    private static var url: URL { Config.home.appendingPathComponent("library.json") }

    static func load() -> (total: Int, firstID: String?, items: [[String: Any]])? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = obj["total"] as? Int,
              let items = obj["items"] as? [[String: Any]] else { return nil }
        return (total, obj["firstID"] as? String, items)
    }

    static func save(total: Int, firstID: String?, items: [[String: Any]]) {
        var obj: [String: Any] = ["total": total, "items": items]
        if let firstID { obj["firstID"] = firstID }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: url)
    }
}
