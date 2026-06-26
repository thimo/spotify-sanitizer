import Foundation

// A process-wide pacer that spaces out request *starts* so a scan stays under
// Spotify's (undisclosed, ~rolling-30s) rate limit instead of bursting. Every
// request reserves the next slot `minInterval` after the previous one, so even
// with concurrency the effective rate is capped.
actor RequestPacer {
    static let shared = RequestPacer()

    // ~5 requests/second. Conservative on purpose: a full scan is a few hundred
    // requests and we'd rather it take ~40s than trip a multi-hour ban.
    private let minInterval: TimeInterval = 0.2
    private var nextSlot = Date.distantPast

    func waitForSlot() async {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}
