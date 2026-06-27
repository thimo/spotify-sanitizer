import Foundation

// One ignored thing the user never wants suggested again — a track, a
// replacement, or a whole album/duplicate-set (hence multiple track ids).
public struct IgnoredEntry: Codable, Identifiable, Hashable {
    public let id: UUID
    public let trackIDs: [String]
    public let label: String

    public init(id: UUID = UUID(), trackIDs: [String], label: String) {
        self.id = id
        self.trackIDs = trackIDs
        self.label = label
    }
}

// Persisted across sessions and applied to every future plan.
enum IgnoreList {
    private static var url: URL { Config.home.appendingPathComponent("ignored.json") }

    static func entries() -> [IgnoredEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let entries = try? JSONDecoder().decode([IgnoredEntry].self, from: data) { return entries }
        // Migrate the old id-only format (a flat array of track ids).
        if let ids = try? JSONDecoder().decode([String].self, from: data) {
            return ids.map { IgnoredEntry(trackIDs: [$0], label: $0) }
        }
        return []
    }

    static var ids: Set<String> { Set(entries().flatMap(\.trackIDs)) }

    static func add(_ entry: IgnoredEntry) {
        var all = entries()
        let set = Set(entry.trackIDs)
        guard !all.contains(where: { Set($0.trackIDs) == set }) else { return }  // dedupe
        all.append(entry)
        save(all)
    }

    static func remove(_ id: UUID) {
        save(entries().filter { $0.id != id })
    }

    private static func save(_ entries: [IgnoredEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(entries.sorted { $0.label.lowercased() < $1.label.lowercased() }) {
            try? data.write(to: url)
        }
    }

    // Drop anything the user has ignored from a freshly built plan.
    static func filter(_ plan: Plan) -> Plan {
        let ignored = ids
        guard !ignored.isEmpty else { return plan }
        var p = plan
        p.removals.removeAll { ignored.contains($0.card.id) }
        p.replacements.removeAll { ignored.contains($0.dead.id) }
        p.albumDuplicates.removeAll { dup in dup.releases.contains { $0.trackIDs.contains { ignored.contains($0) } } }
        p.completions = p.completions.compactMap { completion in
            var c = completion
            c.tracks.removeAll { !$0.liked && ignored.contains($0.card.id) }
            c.likedCount = c.tracks.filter { $0.liked }.count
            c.total = c.tracks.count
            return c.missing.isEmpty ? nil : c
        }
        return p
    }
}
