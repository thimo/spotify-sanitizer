import Foundation

// The brain: turns a list of liked tracks into a reviewable Plan. Ported from
// analyzer.rb — the tunable knobs live in Options.
struct Analyzer {
    struct Options {
        var completionThreshold = 0.70
        // Tracks at/under this length count as skits: excluded from completion
        // math and never proposed. 90s catches short interludes (Hoed Rits 62s,
        // Vlammetjes 90s); the cost is that genuinely short songs are skipped too.
        var skitMaxSeconds = 90
        var dropUnplayable = true
        var findAlternatives = false
        var fuzzyAlternatives = false
        var completeAlbums = true
    }

    // album_type preference for keeper selection: lower wins.
    static let albumTypeRank: [String: Int] = ["album": 0, "single": 1, "compilation": 2]

    // How many album-tracklist / alternative fetches to run at once.
    static let fetchConcurrency = 8

    var tracks: [Track]
    var library: LibraryProviding?
    var options: Options
    var progress: ((ScanProgress) -> Void)?

    private func report(_ p: ScanProgress) { progress?(p) }

    func buildPlan() async throws -> Plan {
        var plan = Plan()
        var kept = tracks

        if options.dropUnplayable { kept = try await dropUnplayable(kept, &plan) }
        kept = dedupe(kept, &plan)
        if options.completeAlbums, library != nil { try await completeAlbums(kept, &plan) }

        plan.stats = [
            "liked_tracks_scanned": tracks.count,
            "duplicates_removed":   plan.removals.filter { $0.reason.hasPrefix("duplicate") }.count,
            "unplayable_removed":   plan.removals.filter { $0.reason.hasPrefix("unplayable") }.count,
            "unplayable_replaced":  plan.replacements.count,
            "additions_suggested":  plan.additionsCount,
            "albums_kept":          Set(kept.compactMap { $0.albumID }).count
        ]
        return plan
    }

    // MARK: - stages

    private func dropUnplayable(_ tracks: [Track], _ plan: inout Plan) async throws -> [Track] {
        let playable = tracks.filter { $0.playable }
        let dead = tracks.filter { !$0.playable }

        // No alternative lookup: just drop the dead ones.
        guard options.findAlternatives, let library else {
            dead.forEach { plan.remove($0, reason: "unplayable in your market") }
            return playable
        }

        // Look up alternatives concurrently.
        report(ScanProgress(label: "Finding alternatives", done: 0, total: dead.count))
        let fuzzy = options.fuzzyAlternatives
        let found = try await boundedMap(dead, limit: Analyzer.fetchConcurrency, onProgress: { done in
            self.report(ScanProgress(label: "Finding alternatives", done: done, total: dead.count))
        }) { track in
            (track, try await library.findAlternative(track, fuzzy: fuzzy))
        }

        for (track, result) in found {
            if let result {
                let reason = result.fuzzy
                    ? "unplayable — likely the same song (verify)"
                    : "unplayable in your market — same recording (ISRC) plays here"
                plan.replace(track, with: result.track, reason: reason, fuzzy: result.fuzzy)
            } else {
                plan.remove(track, reason: "unplayable in your market")
            }
        }
        return playable
    }

    // Collapse "same recording, different release" clusters down to one keeper.
    private func dedupe(_ tracks: [Track], _ plan: inout Plan) -> [Track] {
        var kept: [Track] = []
        for (_, cluster) in Dictionary(grouping: tracks, by: { $0.fuzzyKey }) {
            guard cluster.count > 1 else { kept.append(cluster[0]); continue }
            let keeper = cluster.min { rankKey($0) < rankKey($1) }!
            kept.append(keeper)
            for loser in cluster where loser.id != keeper.id {
                plan.remove(loser, reason: duplicateReason(loser, keeper), keeper: keeper)
            }
        }
        return kept
    }

    // Ordered keeper rules: playable > explicit > album>single>compilation >
    // earliest added_at.
    private func rankKey(_ t: Track) -> (Int, Int, Int, String) {
        (t.playable ? 0 : 1,
         t.explicit ? 0 : 1,
         Analyzer.albumTypeRank[t.albumType ?? ""] ?? 9,
         t.addedAt ?? "")
    }

    private func duplicateReason(_ loser: Track, _ keeper: Track) -> String {
        if !loser.explicit && keeper.explicit {
            return "duplicate — clean version, keeping explicit"
        }
        let loserRank = Analyzer.albumTypeRank[loser.albumType ?? ""] ?? 9
        let keeperRank = Analyzer.albumTypeRank[keeper.albumType ?? ""] ?? 9
        if loserRank > keeperRank {
            return "duplicate — \(loser.albumType ?? "?") version, keeping \(keeper.albumType ?? "?")"
        }
        return "duplicate — keeping one copy"
    }

    // For albums you've mostly liked (ignoring skits), suggest the missing songs.
    private func completeAlbums(_ kept: [Track], _ plan: inout Plan) async throws {
        guard let library else { return }

        // Candidates that clear the rough gate — cheap, no network yet.
        let candidates = Dictionary(grouping: kept.filter { $0.albumType == "album" && $0.albumID != nil },
                                    by: { $0.albumID! })
            .compactMap { (albumID, liked) -> (String, [Track])? in
                let total = liked[0].albumTotalTracks
                guard total > 0 else { return nil }
                let likedReal = liked.filter { !$0.isSkit(maxSeconds: options.skitMaxSeconds) }
                guard Double(likedReal.count) / Double(total) >= options.completionThreshold else { return nil }
                return (albumID, liked)
            }
        guard !candidates.isEmpty else { return }

        // Fetch the full tracklists concurrently.
        report(ScanProgress(label: "Checking albums", done: 0, total: candidates.count))
        let fetched = try await boundedMap(candidates, limit: Analyzer.fetchConcurrency, onProgress: { done in
            self.report(ScanProgress(label: "Checking albums", done: done, total: candidates.count))
        }) { (albumID, liked) in
            (liked, try await library.albumTracks(albumID, albumName: liked[0].albumName, albumImage: liked[0].imageURL))
        }

        // Build the suggestions sequentially (cheap, and keeps plan access simple).
        for (liked, full) in fetched {
            let likedIDs = Set(liked.compactMap { $0.id })
            // The album's real (non-skit) tracklist, in order.
            let realTracks = full.filter { !$0.isSkit(maxSeconds: options.skitMaxSeconds) }
            let likedReal = realTracks.filter { $0.id.map { likedIDs.contains($0) } ?? false }
            let missing = realTracks.filter { !($0.id.map { likedIDs.contains($0) } ?? false) }
            if missing.isEmpty { continue } // already complete (minus skits)
            if realTracks.isEmpty || Double(likedReal.count) / Double(realTracks.count) < options.completionThreshold { continue }

            plan.addCompletion(album: liked[0].albumName, tracks: realTracks, likedIDs: likedIDs)
        }
    }
}
