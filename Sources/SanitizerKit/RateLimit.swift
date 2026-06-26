import Foundation

// Persists a rate-limit cooldown deadline so the app can show the countdown
// (and refuse to scan) even after a restart.
enum RateLimit {
    private static var url: URL { Config.home.appendingPathComponent("rate-limit") }

    static func record(retryAfter seconds: Int) {
        let until = Date().addingTimeInterval(Double(seconds)).timeIntervalSince1970
        try? Data("\(until)".utf8).write(to: url)
    }

    static func clearIfPresent() {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // The deadline if still in the future, else nil (clearing a stale file).
    static var until: Date? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let epoch = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let date = Date(timeIntervalSince1970: epoch)
        if date > Date() { return date }
        clearIfPresent()
        return nil
    }
}
