import Foundation

// The brain: turns a list of liked tracks into a reviewable Plan. Ported from
// analyzer.rb — the tunable knobs live in Options.
struct Analyzer {
    struct Options {
        var completionThreshold = 0.70
        var skitMaxSeconds = 60
        var dropUnplayable = true
        var findAlternatives = false
        var completeAlbums = true
    }

    // album_type preference for keeper selection: lower wins.
    static let albumTypeRank: [String: Int] = ["album": 0, "single": 1, "compilation": 2]

    var tracks: [Track]
    var library: LibraryProviding?
    var options: Options

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
            "additions_suggested":  plan.additions.count,
            "albums_kept":          Set(kept.compactMap { $0.albumID }).count
        ]
        return plan
    }

    // MARK: - stages

    private func dropUnplayable(_ tracks: [Track], _ plan: inout Plan) async throws -> [Track] {
        let playable = tracks.filter { $0.playable }
        let dead = tracks.filter { !$0.playable }
        for track in dead {
            if let alt = try await alternative(for: track) {
                plan.replace(track, with: alt,
                             reason: "unplayable in your market — same recording (ISRC) plays here")
            } else {
                plan.remove(track, reason: "unplayable in your market")
            }
        }
        return playable
    }

    private func alternative(for track: Track) async throws -> Track? {
        guard options.findAlternatives, let library else { return nil }
        return try await library.findAlternative(track)
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
        let albums = Dictionary(grouping: kept.filter { $0.albumType == "album" && $0.albumID != nil },
                                by: { $0.albumID! })

        for (albumID, liked) in albums {
            let total = liked[0].albumTotalTracks
            if total == 0 { continue }

            let likedReal = liked.filter { !$0.isSkit(maxSeconds: options.skitMaxSeconds) }
            // Rough gate before spending an API call on the full tracklist.
            if Double(likedReal.count) / Double(total) < options.completionThreshold { continue }

            let full = try await library.albumTracks(albumID, albumName: liked[0].albumName)
            let likedIDs = Set(liked.compactMap { $0.id })
            let missing = full
                .filter { track in !(track.id.map { likedIDs.contains($0) } ?? false) }
                .filter { !$0.isSkit(maxSeconds: options.skitMaxSeconds) }
            if missing.isEmpty { continue } // already complete (minus skits)

            let realTotal = full.filter { !$0.isSkit(maxSeconds: options.skitMaxSeconds) }.count
            if realTotal == 0 || Double(likedReal.count) / Double(realTotal) < options.completionThreshold { continue }

            for track in missing {
                plan.add(track, reason: "you like \(likedReal.count)/\(realTotal) of \"\(liked[0].albumName)\"")
            }
        }
    }
}
