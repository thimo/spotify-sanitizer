import Foundation

// Track ids the user never wants suggested again. Persisted across sessions and
// applied to every future plan.
enum IgnoreList {
    private static var url: URL { Config.home.appendingPathComponent("ignored.json") }

    static var ids: Set<String> {
        guard let data = try? Data(contentsOf: url),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(array)
    }

    static func add(_ newIDs: [String]) {
        let merged = ids.union(newIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(merged.sorted()) { try? data.write(to: url) }
    }

    // Drop anything the user has ignored from a freshly built plan.
    static func filter(_ plan: Plan) -> Plan {
        let ignored = ids
        guard !ignored.isEmpty else { return plan }
        var p = plan
        p.removals.removeAll { ignored.contains($0.card.id) }
        p.replacements.removeAll { ignored.contains($0.dead.id) }
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
