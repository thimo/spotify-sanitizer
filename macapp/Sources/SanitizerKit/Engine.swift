import Foundation

// Public façade over the engine. The UI and the verify runner talk to this and
// nothing else; the rest of SanitizerKit stays internal.
public enum Engine {
    public static func loggedIn() -> Bool { Auth.loggedIn() }
    public static func clientIDIsSet() -> Bool { (try? Config.clientID()) != nil }

    public static func login() async throws { try await Auth.login() }

    // Fetch the library and build a reviewable plan. Read-only.
    public static func scan(
        market: String? = nil,
        completionThreshold: Double = 0.70,
        skitMaxSeconds: Int = 60,
        dropUnplayable: Bool = true,
        findAlternatives: Bool = false,
        completeAlbums: Bool = true
    ) async throws -> Plan {
        let client = Client()
        let library = Library(client: client, market: market ?? "from_token")
        let tracks = try await library.likedTracks()

        var options = Analyzer.Options()
        options.completionThreshold = completionThreshold
        options.skitMaxSeconds = skitMaxSeconds
        options.dropUnplayable = dropUnplayable
        options.findAlternatives = findAlternatives
        options.completeAlbums = completeAlbums

        return try await Analyzer(tracks: tracks, library: library, options: options).buildPlan()
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
}
