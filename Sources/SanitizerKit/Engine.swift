import Foundation

// Public façade over the engine. The UI and the verify runner talk to this and
// nothing else; the rest of SanitizerKit stays internal.
public enum Engine {
    public static func loggedIn() -> Bool { Auth.loggedIn() }
    public static func clientIDIsSet() -> Bool { (try? Config.clientID()) != nil }
    // A persisted rate-limit cooldown deadline, if one is still in effect.
    public static var rateLimitedUntil: Date? { RateLimit.until }
    public static let redirectURI = Config.defaultRedirectURI

    public static func saveClientID(_ id: String) {
        Config.saveConfig(["client_id": id.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    public static func login() async throws { try await Auth.login() }

    // One lightweight authenticated request (refreshes the token as a side
    // effect). Throws ApiError.rateLimited with the remaining seconds if banned.
    public static func ping() async throws {
        _ = try await Client().get("/me")
    }

    // Fetch the library and build a reviewable plan. Read-only.
    public static func scan(
        market: String? = nil,
        completionThreshold: Double = 0.70,
        skitMaxSeconds: Int = 60,
        dropUnplayable: Bool = true,
        findAlternatives: Bool = false,
        fuzzyAlternatives: Bool = false,
        completeAlbums: Bool = true,
        progress: ((ScanProgress) -> Void)? = nil
    ) async throws -> Plan {
        let started = Date()
        let client = Client()
        let library = Library(client: client, market: market ?? "from_token")

        progress?(ScanProgress(label: "Fetching liked songs", done: 0, total: 0))
        let fetchStart = Date()
        let tracks = try await library.likedTracks { done, total in
            progress?(ScanProgress(label: "Fetching liked songs", done: done, total: total))
        }
        Log.scan("fetched \(tracks.count) liked tracks in \(Log.since(fetchStart))s")

        var options = Analyzer.Options()
        options.completionThreshold = completionThreshold
        options.skitMaxSeconds = skitMaxSeconds
        options.dropUnplayable = dropUnplayable
        options.findAlternatives = findAlternatives
        options.fuzzyAlternatives = fuzzyAlternatives
        options.completeAlbums = completeAlbums

        let analyzeStart = Date()
        var analyzer = Analyzer(tracks: tracks, library: library, options: options)
        analyzer.progress = progress
        let plan = try await analyzer.buildPlan()
        Log.scan("analyzed in \(Log.since(analyzeStart))s "
                 + "(\(plan.removals.count) remove, \(plan.replacements.count) replace, \(plan.additionsCount) add); "
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

    public static func cachePlan(_ plan: Plan, scannedAt: Date = Date()) {
        let cached = CachedPlan(plan: plan, scannedAt: scannedAt)
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

public extension Engine {
    // A fixture plan for UI work — no network, no auth, no rate limit. Artwork
    // uses Lorem Picsum (stable per seed) so layout/thumbnails are realistic.
    static func samplePlan() -> Plan {
        // `play` is a real Spotify track id so the open-arrow actually navigates
        // in the demo (the display ids are placeholders). Defaults to a Rickroll.
        func card(_ id: String, _ artist: String, _ title: String, _ album: String,
                  _ secs: Int, explicit: Bool = false, num: Int? = nil,
                  play: String = "4cOdK2wGLETKBW3PvgPWqT") -> Card {
            Card(id: id, artist: artist, title: title, album: album, explicit: explicit,
                 durationMs: secs * 1000, trackNumber: num,
                 image: "https://picsum.photos/seed/\(id)/100",
                 url: "https://open.spotify.com/track/\(play)",
                 uri: "spotify:track:\(play)")
        }

        var plan = Plan()
        plan.removals = [
            .init(card: card("dup1", "Daft Punk", "Get Lucky", "Random Access Memories", 248, play: "69kOkLUCkxIZYexIgSG8rq"),
                  reason: "duplicate — keeping one copy",
                  keeper: card("dup1k", "Daft Punk", "Get Lucky", "Random Access Memories", 369, play: "69kOkLUCkxIZYexIgSG8rq")),
            .init(card: card("cln1", "Kendrick Lamar", "DNA.", "DAMN.", 185, play: "6HZILIRieu8S0iqY8kIKhj"),
                  reason: "duplicate — clean version, keeping explicit",
                  keeper: card("exp1", "Kendrick Lamar", "DNA.", "DAMN.", 185, explicit: true, play: "6HZILIRieu8S0iqY8kIKhj")),
            .init(card: card("dead1", "De La Soul", "Saturdays", "Swing", 197),
                  reason: "unplayable in your market", keeper: nil)
        ]
        plan.replacements = [
            .init(dead: card("dead2", "Santa Esmeralda", "Don't Let Me Be Misunderstood", "Kill Bill OST (PA)", 628),
                  alternative: card("alt2", "Santa Esmeralda", "Don't Let Me Be Misunderstood", "House Of The Rising Sun", 628),
                  reason: "unplayable in your market — same recording (ISRC) plays here", fuzzy: false)
        ]
        func entry(_ num: Int, _ id: String, _ title: String, _ secs: Int, liked: Bool, play: String = "4cOdK2wGLETKBW3PvgPWqT") -> Plan.AlbumTrack {
            Plan.AlbumTrack(card: card(id, "Makaveli", title, "The Don Killuminati", secs, explicit: true, num: num, play: play), liked: liked)
        }
        plan.completions = [
            Plan.AlbumCompletion(album: "The Don Killuminati: The 7 Day Theory", likedCount: 4, total: 7, tracks: [
                entry(1, "dk1", "Bomb First (My Second Reply)", 267, liked: true),
                entry(2, "dk2", "Hail Mary", 309, liked: false, play: "6HZILIRieu8S0iqY8kIKhj"),
                entry(3, "dk3", "Toss It Up", 304, liked: true),
                entry(4, "dk4", "To Live & Die in L.A.", 273, liked: false, play: "69kOkLUCkxIZYexIgSG8rq"),
                entry(5, "dk5", "Hold Ya Head", 250, liked: true),
                entry(6, "dk6", "Against All Odds", 277, liked: false),
                entry(7, "dk7", "Life of an Outlaw", 268, liked: true)
            ])
        ]
        plan.stats = [
            "liked_tracks_scanned": 3331, "duplicates_removed": 166, "unplayable_removed": 52,
            "unplayable_replaced": 1, "additions_suggested": 145, "albums_kept": 1139
        ]
        return plan
    }
}
