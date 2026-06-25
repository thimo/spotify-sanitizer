import Foundation

// Executes selected changes against the library and writes a reversal log so
// any run can be undone. Same log shape/location as the Ruby apply.rb, so the
// two are interoperable. Ported from apply.rb.
struct Apply {
    var client: Client
    var logDir: URL

    init(client: Client = Client(), logDir: URL = Config.home.appendingPathComponent("logs")) {
        self.client = client
        self.logDir = logDir
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    @discardableResult
    func run(removeIDs: [String], addIDs: [String]) async throws -> URL {
        if !removeIDs.isEmpty { try await client.delete("/me/tracks", ids: removeIDs) }
        if !addIDs.isEmpty { try await client.put("/me/tracks", ids: addIDs) }
        return try writeLog(removed: removeIDs, added: addIDs)
    }

    // Inverts a reversal log: re-like what we removed, unlike what we added.
    func undo(logURL: URL) async throws -> (reliked: Int, unliked: Int) {
        let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: logURL))) as? [String: Any] ?? [:]
        let removed = obj["removed"] as? [String] ?? []
        let added = obj["added"] as? [String] ?? []
        if !removed.isEmpty { try await client.put("/me/tracks", ids: removed) }
        if !added.isEmpty { try await client.delete("/me/tracks", ids: added) }
        return (removed.count, added.count)
    }

    private func writeLog(removed: [String], added: [String]) throws -> URL {
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = logDir.appendingPathComponent("apply-\(stampFormatter.string(from: Date())).json")
        let payload: [String: Any] = [
            "applied_at": ISO8601DateFormatter().string(from: Date()),
            "removed": removed,
            "added": added
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]).write(to: url)
        return url
    }
}
