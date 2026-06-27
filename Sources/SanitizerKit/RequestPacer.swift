import Foundation

// A process-wide pacer that spaces out request *starts* so a scan stays under
// Spotify's (undisclosed, ~rolling-30s) rate limit instead of bursting. Every
// request reserves the next slot `minInterval` after the previous one, so even
// with concurrency the effective rate is capped.
actor RequestPacer {
    static let shared = RequestPacer()

    // ~2.5 requests/second. Spotify's limit is an undisclosed rolling-30s count
    // (community estimate ~90/30s); pace well under it so a few-hundred-request
    // scan (~80s) doesn't trip a multi-hour ban. Slow beats banned.
    private let minInterval: TimeInterval = 0.4
    private var nextSlot = Date.distantPast
    private(set) var count = 0   // requests since the last reset (per-scan diagnostic)

    func waitForSlot() async {
        count += 1
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    func reset() { count = 0 }
    func current() -> Int { count }
}
