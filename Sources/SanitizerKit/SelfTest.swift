import Foundation

public struct SelfTestResult {
    public var passed: Int
    public var failures: [String]
    public var ok: Bool { failures.isEmpty }
}

public extension Engine {
    // Pure analyzer self-tests (no network), mirroring test/test_analyzer.rb.
    // Lives here rather than in an XCTest target because XCTest needs full Xcode.
    static func selfTest() async -> SelfTestResult {
        var passed = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if condition { passed += 1 } else { failures.append(message) }
        }

        func saved(name: String, artist: String = "Artist", album: String = "Album",
                   albumType: String = "album", total: Int = 10, explicit: Bool = false,
                   isrc: String? = nil, durationMs: Int = 200_000, playable: Bool = true,
                   addedAt: String = "2020-01-01T00:00:00Z", id: String? = nil) -> [String: Any] {
            let tid = id ?? "id-\(name)-\(album)-\(explicit)".filter { $0.isLetter || $0.isNumber }
            let track: [String: Any] = [
                "id": tid, "name": name, "explicit": explicit,
                "duration_ms": durationMs, "is_playable": playable,
                "track_number": 1, "disc_number": 1,
                "external_ids": ["isrc": isrc as Any],
                "artists": [["name": artist]],
                "album": ["id": "alb-\(album)", "name": album, "album_type": albumType, "total_tracks": total]
            ]
            return ["added_at": addedAt, "track": track]
        }

        func buildPlan(_ saveds: [[String: Any]], findAlternatives: Bool = false,
                       library: LibraryProviding? = nil) async -> Plan {
            var options = Analyzer.Options()
            options.completeAlbums = false
            options.findAlternatives = findAlternatives
            let tracks = saveds.map { Track($0) }
            return (try? await Analyzer(tracks: tracks, library: library, options: options).buildPlan()) ?? Plan()
        }

        struct StubLibrary: LibraryProviding {
            var alternative: Track?
            func albumTracks(_ albumID: String, albumName: String?) async throws -> [Track] { [] }
            func findAlternative(_ track: Track) async throws -> Track? { alternative }
        }

        // keeps explicit over clean
        var plan = await buildPlan([saved(name: "Song", explicit: false, id: "clean"),
                                    saved(name: "Song", explicit: true, id: "dirty")])
        check(plan.removals.map { $0.card.id } == ["clean"], "explicit>clean: wrong removal \(plan.removals.map { $0.card.id })")
        check(plan.removals.first?.reason.contains("explicit") ?? false, "explicit>clean: reason missing 'explicit'")

        // prefers album over compilation
        plan = await buildPlan([saved(name: "Hit", album: "Greatest", albumType: "compilation", id: "comp"),
                                saved(name: "Hit", album: "Debut", albumType: "album", id: "alb")])
        check(plan.removals.map { $0.card.id } == ["comp"], "album>compilation: wrong removal")

        // drops unplayable
        plan = await buildPlan([saved(name: "Gone", playable: false, id: "dead")])
        check(plan.removals.map { $0.card.id } == ["dead"], "unplayable: not removed")
        check(plan.removals.first?.reason.contains("unplayable") ?? false, "unplayable: reason missing")

        // distinct songs not merged
        plan = await buildPlan([saved(name: "One", id: "a"), saved(name: "Two", id: "b")])
        check(plan.removals.isEmpty, "distinct songs merged")

        // remaster collapses with original
        plan = await buildPlan([saved(name: "Classic", addedAt: "2019-01-01T00:00:00Z", id: "orig"),
                                saved(name: "Classic - 2011 Remaster", addedAt: "2021-01-01T00:00:00Z", id: "remast")])
        check(plan.removals.count == 1, "remaster did not collapse (\(plan.removals.count))")

        // skit detection
        check(Track(saved(name: "Interlude")).isSkit(), "skit: title not detected")
        check(Track(saved(name: "Short bit", durationMs: 30_000)).isSkit(), "skit: short not detected")
        check(!Track(saved(name: "Real Song", durationMs: 200_000)).isSkit(), "skit: false positive")

        // find-alternatives replaces unplayable
        let alt = Track(saved(name: "Gone", album: "Reissue", isrc: "USABC1234567", playable: true, id: "alive"))
        plan = await buildPlan([saved(name: "Gone", isrc: "USABC1234567", playable: false, id: "dead")],
                               findAlternatives: true, library: StubLibrary(alternative: alt))
        check(plan.removals.isEmpty, "replace: dead still removed")
        check(plan.replacements.count == 1, "replace: no replacement")
        check(plan.replacements.first?.dead.id == "dead" && plan.replacements.first?.alternative.id == "alive",
              "replace: wrong pair")

        // unplayable without alternative falls back to removal
        plan = await buildPlan([saved(name: "Gone", playable: false, id: "dead")],
                               findAlternatives: true, library: StubLibrary(alternative: nil))
        check(plan.removals.map { $0.card.id } == ["dead"], "fallback: not removed")
        check(plan.replacements.isEmpty, "fallback: spurious replacement")

        return SelfTestResult(passed: passed, failures: failures)
    }
}
