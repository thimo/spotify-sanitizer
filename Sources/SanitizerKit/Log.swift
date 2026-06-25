import Foundation
import OSLog

// Logging that's inspectable after the fact: every line is appended to a plain
// text file (readable/greppable) AND mirrored to os.Logger for Console.app.
//   tail -f ~/.config/spotify-sanitizer/logs/app.log
enum Log {
    private static let subsystem = "nl.defrog.spotify-sanitizer"
    private static let lock = NSLock()
    private static let maxBytes = 512 * 1024   // rotate past this; keep one backup
    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static var fileURL: URL {
        let dir = Config.home.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }

    static func scan(_ message: String) { line("scan", message) }
    static func net(_ message: String) { line("net", message) }
    static func auth(_ message: String) { line("auth", message) }

    // Seconds elapsed since `start`, for phase timing logs.
    static func since(_ start: Date) -> String { String(format: "%.2f", Date().timeIntervalSince(start)) }

    private static func line(_ category: String, _ message: String) {
        Logger(subsystem: subsystem, category: category).log("\(message, privacy: .public)")

        let text = "\(timestamp.string(from: Date())) [\(category)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        let url = fileURL
        resetIfTooLarge(url)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    // Once app.log passes maxBytes, delete it and start fresh — no backups.
    // Caller holds the lock.
    private static func resetIfTooLarge(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        if size >= maxBytes { try? FileManager.default.removeItem(at: url) }
    }
}
