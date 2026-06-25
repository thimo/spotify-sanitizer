import Foundation

// Public façade over the engine. The UI and the verify runner talk to this and
// nothing else; the rest of SanitizerKit stays internal.
public enum Engine {
    public static func loggedIn() -> Bool { Auth.loggedIn() }
    public static func clientIDIsSet() -> Bool { (try? Config.clientID()) != nil }
    public static let redirectURI = Config.defaultRedirectURI

    public static func saveClientID(_ id: String) {
        Config.saveConfig(["client_id": id.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    public static func login() async throws { try await Auth.login() }

    // Fetch the library and build a reviewable plan. Read-only.
    public static func scan(
        market: String? = nil,
        completionThreshold: Double = 0.70,
        skitMaxSeconds: Int = 60,
        dropUnplayable: Bool = true,
        findAlternatives: Bool = false,
        completeAlbums: Bool = true,
        progress: ((ScanProgress) -> Void)? = nil
    ) async throws -> Plan {
        let started = Date()
        let client = Client()
        let library = Library(client: client, market: market ?? "from_token")

        progress?(ScanProgress(label: "Fetching liked songs", done: 0, total: 0))
        let fetchStart = Date()
        let tracks = try await library.likedTracks { count in
            progress?(ScanProgress(label: "Fetching liked songs", done: count, total: 0))
        }
        Log.scan("fetched \(tracks.count) liked tracks in \(Log.since(fetchStart))s")

        var options = Analyzer.Options()
        options.completionThreshold = completionThreshold
        options.skitMaxSeconds = skitMaxSeconds
        options.dropUnplayable = dropUnplayable
        options.findAlternatives = findAlternatives
        options.completeAlbums = completeAlbums

        let analyzeStart = Date()
        var analyzer = Analyzer(tracks: tracks, library: library, options: options)
        analyzer.progress = progress
        let plan = try await analyzer.buildPlan()
        Log.scan("analyzed in \(Log.since(analyzeStart))s "
                 + "(\(plan.removals.count) remove, \(plan.replacements.count) replace, \(plan.additions.count) add); "
                 + "scan total \(Log.since(started))s")
        return plan
    }

    // Execute the selected unlikes/likes and return the reversal-log URL.
    @discardableResult
    public static func apply(removeIDs: [String], addIDs: [String]) async throws -> URL {
        try await Apply().run(removeIDs: removeIDs, addIDs: addIDs)
    }

    public static func undo(logURL: URL) async throws -> (reliked: Int, unliked: Int) {
        try await Apply().undo(logURL: logURL)
    }

    // Most recent reversal log, if any (for a one-click Undo).
    public static var latestLog: URL? {
        let dir = Config.home.appendingPathComponent("logs")
        let logs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "json" } ?? []
        return logs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }.first
    }

    // MARK: - Plan cache (so a scan survives a restart and isn't re-fetched)

    private static var planCacheURL: URL { Config.home.appendingPathComponent("last-plan.json") }

    public static func cachePlan(_ plan: Plan) {
        let cached = CachedPlan(plan: plan, scannedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(cached) else { return }
        try? data.write(to: planCacheURL)
    }

    public static func cachedPlan() -> CachedPlan? {
        guard let data = try? Data(contentsOf: planCacheURL) else { return nil }
        return try? JSONDecoder().decode(CachedPlan.self, from: data)
    }

    public static func clearCachedPlan() {
        try? FileManager.default.removeItem(at: planCacheURL)
    }
}

public struct CachedPlan: Codable {
    public var plan: Plan
    public var scannedAt: Date
}
