import Foundation
import SanitizerKit

// Headless engine check: runs a real scan against the cached token and prints
// the plan stats, so we can compare parity with the Ruby CLI without a UI.
let args = CommandLine.arguments
let findAlternatives = args.contains("--find-alternatives")
let market = args.first { $0.hasPrefix("--market=") }.map { String($0.dropFirst("--market=".count)) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}

if args.contains("--selftest") {
    let result = await Engine.selfTest()
    if result.ok {
        print("self-test: \(result.passed) checks passed")
        exit(0)
    } else {
        print("self-test: \(result.passed) passed, \(result.failures.count) FAILED")
        result.failures.forEach { print("  ✗ \($0)") }
        exit(1)
    }
}

guard Engine.loggedIn() else { fail("Not logged in. Run the Ruby CLI `login` first.") }

do {
    let started = Date()
    let plan = try await Engine.scan(market: market, findAlternatives: findAlternatives) { p in
        let bar = p.total > 0 ? " \(p.done)/\(p.total)" : (p.done > 0 ? " \(p.done)" : "")
        FileHandle.standardError.write(Data("\r\(p.label)\(bar)            ".utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))

    let order = ["liked_tracks_scanned", "duplicates_removed", "unplayable_removed",
                 "unplayable_replaced", "additions_suggested", "albums_kept"]
    print(String(repeating: "=", count: 50))
    for key in order {
        print(String(format: "  %-22s %d", (key as NSString).utf8String!, plan.stats[key] ?? 0))
    }
    print(String(repeating: "=", count: 50))
    FileHandle.standardError.write(Data(String(format: "scan took %.1fs\n", Date().timeIntervalSince(started)).utf8))

    if !plan.replacements.isEmpty {
        print("\nREPLACE:")
        for r in plan.replacements {
            print("  ✗ \(r.dead.artist) — \(r.dead.title)")
            print("  ✓ \(r.alternative.artist) — \(r.alternative.title) (\(r.alternative.album))")
        }
    }
} catch {
    fail(error.localizedDescription)
}
