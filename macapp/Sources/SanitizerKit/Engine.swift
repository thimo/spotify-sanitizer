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
}
