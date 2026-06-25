import Foundation

// Coarse scan progress for the UI. total == 0 means indeterminate (the page
// count of the library fetch isn't known up front).
public struct ScanProgress: Sendable {
    public var label: String
    public var done: Int
    public var total: Int

    public init(label: String, done: Int, total: Int) {
        self.label = label
        self.done = done
        self.total = total
    }

    public var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
}
