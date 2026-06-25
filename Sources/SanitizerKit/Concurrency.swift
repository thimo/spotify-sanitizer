import Foundation

// Run `op` over items with at most `limit` concurrent tasks, preserving input
// order. `onProgress` is invoked (on the calling task) with the running count of
// completed items, so callers can drive a progress bar.
func boundedMap<T, R>(_ items: [T], limit: Int,
                      onProgress: ((Int) -> Void)? = nil,
                      _ op: @escaping (T) async throws -> R) async throws -> [R] {
    if items.isEmpty { return [] }
    let limit = max(1, limit)

    return try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        let first = min(limit, items.count)
        while next < first {
            let index = next
            group.addTask { (index, try await op(items[index])) }
            next += 1
        }

        var completed = 0
        while let (index, value) = try await group.next() {
            results[index] = value
            completed += 1
            onProgress?(completed)
            if next < items.count {
                let index = next
                group.addTask { (index, try await op(items[index])) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
