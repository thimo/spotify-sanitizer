import Foundation

enum ConfigError: Error, LocalizedError {
    case noClientID(String)
    var errorDescription: String? {
        switch self { case .noClientID(let m): return m }
    }
}

// The token cache, shared on disk with the Ruby CLI (same JSON shape/location)
// so logging in from either side works for both.
struct Tokens: Codable {
    var access_token: String
    var refresh_token: String?
    var expires_at: Int?
    var expires_in: Int?
    var scope: String?
    var token_type: String?
}

// Locates and reads/writes ~/.config/spotify-sanitizer (overridable with
// SPOTIFY_SANITIZER_HOME), mirroring the Ruby Config module.
enum Config {
    static let defaultRedirectURI = "http://127.0.0.1:8888/callback"
    static let scopes = ["user-library-read", "user-library-modify", "user-read-private"]

    static var home: URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let base: String
        if let h = env["SPOTIFY_SANITIZER_HOME"], !h.isEmpty {
            base = h
        } else {
            let configRoot = env["XDG_CONFIG_HOME"]
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
            base = (configRoot as NSString).appendingPathComponent("spotify-sanitizer")
        }
        let url = URL(fileURLWithPath: base, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var configPath: URL { home.appendingPathComponent("config.json") }
    static var tokensPath: URL { home.appendingPathComponent("tokens.json") }

    static func loadConfig() -> [String: String] {
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }

    static func clientID() throws -> String {
        if let id = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"], !id.isEmpty { return id }
        if let id = loadConfig()["client_id"], !id.isEmpty { return id }
        throw ConfigError.noClientID(
            "No Spotify Client ID found. Save one with the CLI `spotify-sanitizer login --client-id=…`, "
            + "set SPOTIFY_CLIENT_ID, or edit \(configPath.path).")
    }

    static var redirectURI: String { loadConfig()["redirect_uri"] ?? defaultRedirectURI }

    static func saveConfig(_ values: [String: String]) {
        var merged = loadConfig()
        for (k, v) in values { merged[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configPath)
        }
    }

    static func loadTokens() -> Tokens? {
        guard let data = try? Data(contentsOf: tokensPath) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    static func saveTokens(_ tokens: Tokens) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(tokens) else { return }
        try? data.write(to: tokensPath)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokensPath.path)
    }
}
