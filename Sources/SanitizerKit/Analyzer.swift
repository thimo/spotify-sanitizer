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
        // Duplicate whole albums (standard vs deluxe) are chosen at the album
        // level; pull their tracks out so they aren't also listed per-song.
        let dupAlbumTrackIDs = detectDuplicateAlbums(kept, &plan)
        let forDedup = dupAlbumTrackIDs.isEmpty ? kept
            : kept.filter { !($0.id.map { dupAlbumTrackIDs.contains($0) } ?? false) }
        kept = dedupe(forDedup, &plan)
        if options.completeAlbums, library != nil { try await completeAlbums(kept, &plan) }

        plan.stats = [
            "liked_tracks_scanned": tracks.count,
            "duplicates_removed":   plan.removals.filter { $0.reason.hasPrefix("duplicate") }.count,
            "unplayable_removed":   plan.removals.filter { $0.reason.hasPrefix("unplayable") }.count,
            "unplayable_replaced":  plan.replacements.count,
            "duplicate_albums":     plan.albumDuplicates.count,
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
        // How many liked tracks you have per album — used as a keeper tie-break
        // so we keep the copy from an album you're already collecting.
        var albumLikes: [String: Int] = [:]
        for t in tracks { if let a = t.albumID { albumLikes[a, default: 0] += 1 } }

        var kept: [Track] = []
        // Group by song (artist+title), then split each group into clusters of
        // tracks whose durations are close — so 4:47 and 4:49 of the same song
        // cluster, but a 7-minute live version stays separate.
        for (_, group) in Dictionary(grouping: tracks, by: { "\($0.songKey)|\($0.isLive ? "live" : "studio")" }) {
            for cluster in Analyzer.durationClusters(group) {
                guard cluster.count > 1 else { kept.append(cluster[0]); continue }
                let keeper = cluster.min { rankKey($0, albumLikes) < rankKey($1, albumLikes) }!
                kept.append(keeper)
                for loser in cluster where loser.id != keeper.id {
                    plan.remove(loser, reason: duplicateReason(loser, keeper, albumLikes), keeper: keeper)
                }
            }
        }
        return kept
    }

    // Tracks of the same song whose lengths are within this gap are one copy.
    static let durationToleranceMs = 10_000

    // Split same-song tracks into clusters by duration proximity (sorted, new
    // cluster when the gap to the previous exceeds the tolerance).
    static func durationClusters(_ tracks: [Track]) -> [[Track]] {
        let sorted = tracks.sorted { $0.durationMs < $1.durationMs }
        var clusters: [[Track]] = []
        for t in sorted {
            if let last = clusters.last?.last, t.durationMs - last.durationMs <= durationToleranceMs {
                clusters[clusters.count - 1].append(t)
            } else {
                clusters.append([t])
            }
        }
        return clusters
    }

    // Find albums you hold as 2+ releases (e.g. standard + deluxe). A release
    // qualifies with ≥2 liked tracks; a set needs ≥2 such releases. Returns the
    // track ids involved (so they're excluded from per-song dedup).
    private func detectDuplicateAlbums(_ tracks: [Track], _ plan: inout Plan) -> Set<String> {
        var involved = Set<String>()
        for (_, group) in Dictionary(grouping: tracks.filter { $0.albumID != nil }, by: { $0.albumKey }) {
            let byRelease = Dictionary(grouping: group, by: { $0.albumID! }).filter { $0.value.count >= 2 }
            guard byRelease.count >= 2 else { continue }

            var releases = byRelease.map { albumID, ts in
                Plan.AlbumRelease(albumID: albumID, album: ts[0].albumName, artist: ts[0].primaryArtist,
                                  image: ts[0].imageURL, likedCount: ts.count,
                                  totalTracks: ts[0].albumTotalTracks, trackIDs: ts.compactMap { $0.id })
            }
            // Keeper first: most complete (most tracks), then most liked.
            releases.sort { ($0.totalTracks, $0.likedCount) > ($1.totalTracks, $1.likedCount) }
            plan.albumDuplicates.append(Plan.AlbumDuplicate(title: releases[0].album,
                                                            artist: releases[0].artist, releases: releases))
            releases.forEach { involved.formUnion($0.trackIDs) }
        }
        return involved
    }

    private func albumAffinity(_ t: Track, _ albumLikes: [String: Int]) -> Int {
        t.albumID.flatMap { albumLikes[$0] } ?? 0
    }

    // Ordered keeper rules: playable > explicit > album>single>compilation >
    // album you like more of > earliest added_at.
    private func rankKey(_ t: Track, _ albumLikes: [String: Int]) -> (Int, Int, Int, Int, String) {
        (t.playable ? 0 : 1,
         t.explicit ? 0 : 1,
         Analyzer.albumTypeRank[t.albumType ?? ""] ?? 9,
         -albumAffinity(t, albumLikes),   // more liked from this album = better (lower)
         t.addedAt ?? "")
    }

    private func duplicateReason(_ loser: Track, _ keeper: Track, _ albumLikes: [String: Int]) -> String {
        if !loser.explicit && keeper.explicit {
            return "duplicate — clean version, keeping explicit"
        }
        let loserRank = Analyzer.albumTypeRank[loser.albumType ?? ""] ?? 9
        let keeperRank = Analyzer.albumTypeRank[keeper.albumType ?? ""] ?? 9
        if loserRank > keeperRank {
            return "duplicate — \(loser.albumType ?? "?") version, keeping \(keeper.albumType ?? "?")"
        }
        if albumAffinity(keeper, albumLikes) > albumAffinity(loser, albumLikes) {
            return "duplicate — keeping the copy from an album you like more of"
        }
        return "duplicate — keeping the one you added first"
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
            // Match by position (disc + track number), not raw id: Spotify's
            // relinking can change a track's id between the album tracklist and
            // your saved tracks, which made already-added tracks look missing.
            let likedKeys = Set(liked.map { Self.positionKey($0) })
            // Only playable, non-skit tracks: unplayable ones can't be usefully
            // added (they'd just get flagged for removal), so don't suggest them.
            let realTracks = full.filter { $0.playable && !$0.isSkit(maxSeconds: options.skitMaxSeconds) }
            let paired = realTracks.map { ($0, likedKeys.contains(Self.positionKey($0))) }
            let likedCount = paired.filter { $0.1 }.count
            let missingCount = paired.count - likedCount
            if missingCount == 0 { continue } // already complete (minus skits/unplayable)
            if paired.isEmpty || Double(likedCount) / Double(paired.count) < options.completionThreshold { continue }

            plan.addCompletion(album: liked[0].albumName, tracks: paired)
        }
    }

    // Position within an album, stable across relinking.
    private static func positionKey(_ t: Track) -> String { "\(t.discNumber ?? 1)-\(t.trackNumber ?? 0)" }
}
