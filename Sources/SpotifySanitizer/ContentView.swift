import SwiftUI
import AppKit
import SanitizerKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmApply = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            banners
            content
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label("Spotify Sanitizer", systemImage: "music.note.list")
                .font(.headline)

            Spacer()

            if model.loggedIn {
                Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Scan options")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        SettingsView().environmentObject(model)
                    }
                Button {
                    Task { await model.scan() }
                } label: { Label("Scan", systemImage: "arrow.clockwise") }

                if model.lastLog != nil {
                    Button { Task { await model.undo() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                }

                if let plan = model.plan, !plan.isEmpty {
                    let c = model.selectedCounts
                    Button { confirmApply = true } label: {
                        Label("Apply (\(c.unlike)↓ \(c.like)↑)", systemImage: "checkmark.circle")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(c.unlike + c.like == 0)
                }
            }
        }
        .padding(10)
        .disabled(model.isBusy)
        .confirmationDialog("Apply these changes to your Spotify library?",
                            isPresented: $confirmApply, titleVisibility: .visible) {
            let c = model.selectedCounts
            Button("Unlike \(c.unlike), like \(c.like)", role: .destructive) {
                Task { await model.apply() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("scan is read-only; this is the step that changes your library. A reversal log is written so you can Undo.")
        }
    }

    private var banners: some View {
        VStack(spacing: 0) {
            if let until = model.rateLimitedUntil {
                RateLimitBanner(until: until)
            }
            if let error = model.error {
                banner(error, color: .red, icon: "exclamationmark.triangle.fill")
            }
            if let notice = model.notice {
                banner(notice, color: .green, icon: "checkmark.circle.fill")
            }
        }
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text).textSelection(.enabled)
            Spacer()
        }
        .padding(8)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if let label = model.busy {
            Spacer()
            VStack(spacing: 12) {
                if let p = model.progress, let fraction = p.fraction {
                    ProgressView(value: fraction) {
                        Text(p.label)
                    } currentValueLabel: {
                        Text("\(p.done) / \(p.total)").monospacedDigit()
                    }
                    .frame(maxWidth: 320)
                } else {
                    ProgressView()
                    Text(model.progress.map { $0.done > 0 ? "\($0.label) (\($0.done))" : $0.label } ?? label)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        } else if !model.clientIDSet {
            ClientIDSetup().environmentObject(model)
        } else if !model.loggedIn {
            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 44)).foregroundStyle(.green)
                Text("Authorize with Spotify to begin.").foregroundStyle(.secondary)
                Button { Task { await model.login() } } label: { Text("Log in").padding(.horizontal) }
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan = model.plan {
            if plan.isEmpty {
                placeholder("Already spotless", "Nothing to clean up. Monk would approve.", systemImage: "sparkles")
            } else {
                PlanView(plan: plan)
            }
        } else {
            placeholder("Ready", "Press Scan to build a read-only cleanup plan.", systemImage: "magnifyingglass")
        }
    }

    private func placeholder(_ title: String, _ subtitle: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// Scan-option tuning, in a popover. Changes apply to the next scan.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Suggest completing albums", isOn: $model.completeAlbums)
                if model.completeAlbums {
                    HStack {
                        Text("Threshold")
                        Slider(value: $model.completionThreshold, in: 0.5...1.0, step: 0.05)
                        Text("\(Int((model.completionThreshold * 100).rounded()))%")
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Stepper("Skits ≤ \(model.skitMaxSeconds)s", value: $model.skitMaxSeconds, in: 30...150, step: 5)
                }
            } header: {
                Text("Album completion").font(.headline).padding(.top, 4)
            }
            Section {
                Toggle("Remove unplayable", isOn: $model.dropUnplayable)
                Toggle("Find alternatives (ISRC)", isOn: $model.findAlternatives)
                    .help("For unplayable tracks, find the same recording (ISRC) on a playable release")
                if model.findAlternatives {
                    Toggle("Also fuzzy match — verify", isOn: $model.fuzzyAlternatives)
                        .help("If no exact ISRC match, try a title/artist match. May be a different version.")
                }
            } header: {
                Text("Unplayable tracks").font(.headline).padding(.top, 12)
            }
            Section {
                HStack {
                    Image(systemName: model.loggedIn ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.loggedIn ? .green : .secondary)
                    Text(model.loggedIn ? "Logged in" : "Not logged in")
                    Spacer()
                }
                HStack {
                    Button("Re-authorize") { Task { await model.login() } }
                    if model.loggedIn {
                        Button("Log out") { model.logout() }
                    }
                    Spacer()
                }
                Text("Re-authorize if Spotify refuses changes or you changed permissions.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Account").font(.headline).padding(.top, 12)
            }

            Text("Changes apply on the next Scan.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Plan list

struct PlanView: View {
    @EnvironmentObject var model: AppModel
    let plan: Plan
    @State private var collapsed: Set<String> = []

    private func collapseBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { collapsed.contains(key) },
                set: { isOn in if isOn { collapsed.insert(key) } else { collapsed.remove(key) } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statsHeader
                if !plan.removals.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Remove — \(plan.removals.count) to unlike",
                                      ids: plan.removals.map(\.id), collapsed: collapseBinding("remove"))
                        if !collapsed.contains("remove") {
                        ForEach(removalGroups, id: \.reason) { group in
                            let hasKeeper = group.items.first?.keeper != nil
                            VStack(alignment: .leading, spacing: 8) {
                                subHeader(group.reason, ids: group.items.map(\.id))
                                LazyVGrid(columns: gridColumns(hasKeeper ? 440 : 340), spacing: 10) {
                                    ForEach(group.items) { r in
                                        if r.keeper != nil {
                                            DuplicateRow(removal: r)
                                        } else {
                                            CardRow(entryID: r.id, card: r.card, reason: "", accent: .red,
                                                    actionLabel: "Unlike",
                                                    onDo: { await model.doRemoval(r) },
                                                    onIgnore: { model.ignoreRemoval(r) })
                                        }
                                    }
                                }
                            }
                        }
                        }
                    }
                }
                if !plan.replacements.isEmpty {
                    section("Replace — \(plan.replacements.count) unplayable",
                            ids: plan.replacements.map(\.id), minWidth: 360, key: "replace") {
                        ForEach(plan.replacements.sorted { sortKey($0.dead) < sortKey($1.dead) }) { rep in
                            ReplacementRow(entryID: rep.id, replacement: rep)
                        }
                    }
                }
                if !plan.albumDuplicates.isEmpty {
                    section("Duplicate albums — \(plan.albumDuplicates.count) to resolve",
                            ids: [], minWidth: 420, key: "dupalbums") {
                        ForEach(plan.albumDuplicates) { dup in
                            DuplicateAlbumView(dup: dup)
                        }
                    }
                }
                if !plan.completions.isEmpty {
                    section("Add — \(plan.additionsCount) to complete albums",
                            ids: plan.completions.flatMap { $0.missing.map(\.id) }, minWidth: 360, key: "add") {
                        ForEach(plan.completions.sorted { completionKey($0) < completionKey($1) }) { completion in
                            AlbumCompletionView(completion: completion)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // A section header plus an adaptive grid that flows into as many columns as
    // the window width allows (min cell width tuned per section).
    @ViewBuilder
    private func section<Content: View>(_ title: String, ids: [UUID], minWidth: CGFloat, key: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, ids: ids, collapsed: collapseBinding(key))
            if !collapsed.contains(key) {
                LazyVGrid(columns: gridColumns(minWidth), spacing: 10) { content() }
            }
        }
    }

    private func gridColumns(_ minWidth: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: minWidth), spacing: 10, alignment: .top)]
    }

    // Removals grouped by their reason, biggest group first; items by artist→album→title.
    private var removalGroups: [(reason: String, items: [Plan.Removal])] {
        Dictionary(grouping: plan.removals, by: { $0.reason })
            .map { (reason: $0.key, items: $0.value.sorted { sortKey($0.card) < sortKey($1.card) }) }
            .sorted { $0.items.count > $1.items.count }
    }

    // Case-insensitive artist → album → title ordering key.
    private func sortKey(_ c: Card) -> String {
        "\(c.artist.lowercased())\u{1}\(c.album.lowercased())\u{1}\(c.title.lowercased())"
    }

    private func completionKey(_ c: Plan.AlbumCompletion) -> String {
        "\((c.tracks.first?.card.artist ?? "").lowercased())\u{1}\(c.album.lowercased())"
    }

    // Lighter header for a sub-group, with its own select-all/none.
    private func subHeader(_ title: String, ids: [UUID]) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text("\(ids.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
            let allOn = model.allIncluded(ids)
            Button(allOn ? "Select none" : "Select all") { model.setIncluded(ids, !allOn) }
                .font(.caption).buttonStyle(.borderless)
        }
    }

    private var statsHeader: some View {
        let order = [("liked_tracks_scanned", "scanned"), ("duplicates_removed", "duplicates"),
                     ("duplicate_albums", "dup albums"), ("unplayable_removed", "unplayable"),
                     ("unplayable_replaced", "replaced"), ("additions_suggested", "additions"),
                     ("albums_kept", "albums")]
        return VStack(spacing: 6) {
            HStack(spacing: 18) {
                ForEach(order, id: \.0) { key, label in
                    VStack {
                        Text("\(plan.stats[key] ?? 0)").font(.title3.monospacedDigit().bold())
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let scannedAt = model.scannedAt {
                Text("Scanned \(Self.scannedAgo(scannedAt)) — Scan again to refresh.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // Coarse "time ago" — seconds stop mattering after a minute.
    static func scannedAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) hr ago" }
        return "\(s / 86400) d ago"
    }
}

struct SectionHeader: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let ids: [UUID]
    var collapsed: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let collapsed {
                Image(systemName: "chevron.right")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
            }
            Text(title).font(.headline)
            Spacer()
            if !ids.isEmpty {
                let allOn = model.allIncluded(ids)
                Button(allOn ? "Select none" : "Select all") {
                    model.setIncluded(ids, !allOn)
                }
                .font(.caption).textCase(nil).buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { collapsed?.wrappedValue.toggle() }
    }
}

// MARK: - Rows

// Card-style cell background used by every grid item.
private struct CellBackground: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
extension View {
    func cell(_ color: Color) -> some View { modifier(CellBackground(color: color)) }
}

// Non-interactive checkbox indicator — the whole row is the tap target.
struct CheckBox: View {
    let on: Bool
    var body: some View {
        Image(systemName: on ? "checkmark.square.fill" : "square")
            .font(.title3)
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
    }
}

struct Artwork: View {
    let url: String?
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct CardRow: View {
    @EnvironmentObject var model: AppModel
    let entryID: UUID
    let card: Card
    let reason: String
    let accent: Color
    var actionLabel: String? = nil
    var onDo: (() async -> Void)? = nil
    var onIgnore: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(on: model.included(entryID))
            Artwork(url: card.image)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if card.explicit { ExplicitTag() }
                    Text(card.album.isEmpty ? card.artist : "\(card.artist) · \(card.album)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if !reason.isEmpty {
                    Text(reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(card.durationFormatted).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            SpotifyLink(card: card)
            if let onIgnore { IgnoreButton(action: onIgnore) }
            if let actionLabel, let onDo {
                DoButton(id: entryID, label: actionLabel, action: onDo)
            }
        }
        .opacity(model.included(entryID) ? 1 : 0.4)
        .cell(accent)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(entryID) }
    }
}

// One album held as multiple releases: pick the one to keep (default = most
// complete); the other releases' liked tracks get unliked.
struct DuplicateAlbumView: View {
    @EnvironmentObject var model: AppModel
    let dup: Plan.AlbumDuplicate

    var body: some View {
        let keep = model.keptReleaseID(dup)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(dup.artist) — \(dup.title)").font(.headline).lineLimit(1)
                    Text("\(dup.releases.count) releases — keep one")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                IgnoreButton { model.ignoreAlbumDuplicate(dup) }
                DoButton(id: dup.id, label: "Keep chosen") { await model.doAlbumDuplicate(dup) }
            }
            ForEach(dup.releases) { release in
                let isKeep = release.id == keep
                HStack(spacing: 10) {
                    Image(systemName: isKeep ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isKeep ? Color.accentColor : .secondary)
                    Artwork(url: release.image)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(release.album).fontWeight(.medium).lineLimit(1)
                        Text("\(release.likedCount) liked · \(release.totalTracks) tracks")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    AlbumLink(albumID: release.albumID)
                    if isKeep {
                        Text("keep").font(.caption.bold()).foregroundStyle(.green)
                    } else {
                        Text("unlike \(release.likedCount)").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 1)
                .contentShape(Rectangle())
                .onTapGesture { model.keepRelease(dup, release) }
            }
        }
        .cell(.purple)
    }
}

// One partially-liked album: cover + ratio header, then the full tracklist with
// missing tracks tickable and already-liked tracks shown for context.
struct AlbumCompletionView: View {
    @EnvironmentObject var model: AppModel
    let completion: Plan.AlbumCompletion

    private var selectedCount: Int { completion.missing.filter { model.included($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Artwork(url: completion.tracks.first?.card.image)
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.album).font(.headline).lineLimit(1)
                    if let artist = completion.tracks.first?.card.artist, !artist.isEmpty {
                        Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("you like \(completion.likedCount) of \(completion.total) — adding the \(completion.missing.count) missing")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                IgnoreButton { model.ignoreCompletion(completion) }
                DoButton(id: completion.id, label: "Add (\(selectedCount))", disabled: selectedCount == 0) {
                    await model.doCompletion(completion)
                }
            }
            VStack(spacing: 0) {
                ForEach(completion.tracks) { AlbumTrackRow(track: $0) }
            }
            .padding(.leading, 4)
        }
        .cell(.green)
    }
}

struct AlbumTrackRow: View {
    @EnvironmentObject var model: AppModel
    let track: Plan.AlbumTrack

    var body: some View {
        HStack(spacing: 8) {
            if track.liked {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.5))
                    .help("Already in your library")
            } else {
                CheckBox(on: model.included(track.id))
            }
            Text(track.card.trackNumber.map(String.init) ?? "")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.card.title)
                    .foregroundStyle(track.liked ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if track.card.explicit { ExplicitTag() }
                    Text(track.card.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(track.card.durationFormatted).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            SpotifyLink(card: track.card)
        }
        .padding(.vertical, 1)
        .opacity(track.liked ? 1 : (model.included(track.id) ? 1 : 0.45))
        .contentShape(Rectangle())
        .onTapGesture { if !track.liked { model.toggle(track.id) } }
    }
}

// A duplicate: the copy to unlike (✗) over the copy being kept (✓), both with
// album so the difference is visible.
struct DuplicateRow: View {
    @EnvironmentObject var model: AppModel
    let removal: Plan.Removal

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckBox(on: model.included(removal.id))
            VStack(alignment: .leading, spacing: 6) {
                trackLine(removal.card, symbol: "xmark.circle.fill", color: .red)
                if let keeper = removal.keeper {
                    trackLine(keeper, symbol: "checkmark.circle.fill", color: .green)
                }
            }
            Spacer(minLength: 8)
            IgnoreButton { model.ignoreRemoval(removal) }
            DoButton(id: removal.id, label: "Unlike") { await model.doRemoval(removal) }
        }
        .opacity(model.included(removal.id) ? 1 : 0.4)
        .cell(.red)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(removal.id) }
    }

    private func trackLine(_ card: Card, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Artwork(url: card.image)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if card.explicit { ExplicitTag() }
                    Text(card.album.isEmpty ? card.artist : "\(card.artist) · \(card.album)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if let added = shortDate(card.addedAt) {
                    Text("added \(added)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(card.durationFormatted).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            SpotifyLink(card: card)
        }
    }

    // The ISO added_at as a plain YYYY-MM-DD (the differentiator for otherwise
    // identical copies — we keep the earliest).
    private func shortDate(_ iso: String?) -> String? {
        guard let iso, iso.count >= 10 else { return nil }
        return String(iso.prefix(10))
    }
}

struct ReplacementRow: View {
    @EnvironmentObject var model: AppModel
    let entryID: UUID
    let replacement: Plan.Replacement

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckBox(on: model.included(entryID))
            VStack(alignment: .leading, spacing: 6) {
                line(replacement.dead, symbol: "xmark.circle.fill", color: .red)
                line(replacement.alternative, symbol: "checkmark.circle.fill", color: .green)
                HStack(spacing: 6) {
                    if replacement.fuzzy {
                        Text("VERIFY").font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.25), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Text(replacement.reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if model.workingItem == entryID {
                ProgressView().controlSize(.small).frame(width: 120)
            } else {
                HStack(spacing: 6) {
                    IgnoreButton { model.ignoreReplacement(replacement) }
                    Button("Unlike") { Task { await model.unlikeDead(replacement) } }
                        .controlSize(.small).disabled(model.workingItem != nil)
                    Button("Replace") { Task { await model.doReplacement(replacement) } }
                        .controlSize(.small).buttonStyle(.borderedProminent).disabled(model.workingItem != nil)
                }
            }
        }
        .opacity(model.included(entryID) ? 1 : 0.4)
        .cell(.orange)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(entryID) }
    }

    private func line(_ card: Card, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Artwork(url: card.image)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if card.explicit { ExplicitTag() }
                    Text(albumLine(card)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            SpotifyLink(card: card)
        }
    }

    private func albumLine(_ card: Card) -> String {
        card.album.isEmpty ? card.artist : "\(card.artist) · \(card.album)"
    }
}

struct ExplicitTag: View {
    var body: some View {
        Text("E").font(.caption2.bold())
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.secondary.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// Per-item "do this one now" button; shows a spinner while it runs and is
// disabled while any item is being applied.
struct DoButton: View {
    @EnvironmentObject var model: AppModel
    let id: UUID
    let label: String
    var disabled: Bool = false
    let action: () async -> Void

    var body: some View {
        if model.workingItem == id {
            ProgressView().controlSize(.small).frame(width: 64)
        } else {
            Button(label) { Task { await action() } }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(disabled || model.workingItem != nil)
        }
    }
}

// Persistently ignore an item so it's never suggested again.
struct IgnoreButton: View {
    @EnvironmentObject var model: AppModel
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "eye.slash") }
            .buttonStyle(.borderless)
            .help("Ignore — never suggest this again")
            .disabled(model.workingItem != nil)
    }
}

struct AlbumLink: View {
    let albumID: String
    var body: some View {
        if let url = URL(string: "spotify:album:\(albumID)") {
            Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                .help("Open album in Spotify")
        }
    }
}

struct SpotifyLink: View {
    let card: Card
    // Prefer the spotify: URI (opens the desktop app); fall back to the web link.
    private var target: URL? {
        if let uri = card.uri, let u = URL(string: uri) { return u }
        return card.url.flatMap(URL.init(string:))
    }
    var body: some View {
        if let target {
            Link(destination: target) { Image(systemName: "arrow.up.right.square") }
                .help("Open in Spotify")
        }
    }
}

// First-run setup: every user registers their own free Spotify app (Spotify
// only grants >5 users to ≥250k-MAU businesses, so a shared app isn't an option).
struct ClientIDSetup: View {
    @EnvironmentObject var model: AppModel

    private var redirectURI: String { SanitizerKit.Engine.redirectURI }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Connect your Spotify app").font(.title3.bold())
            Text("This needs a free Spotify app of your own (Spotify doesn't allow one shared app). "
                 + "Create one, add the redirect URI below, then paste its Client ID here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)

            Link(destination: URL(string: "https://developer.spotify.com/dashboard")!) {
                Label("Open Spotify Dashboard", systemImage: "safari")
            }
            .controlSize(.large)

            HStack(spacing: 8) {
                Text("Redirect URI").font(.caption).foregroundStyle(.secondary)
                Text(redirectURI).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 5))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(redirectURI, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy redirect URI")
            }

            HStack {
                TextField("Client ID", text: $model.clientIDInput)
                    .textFieldStyle(.roundedBorder).frame(width: 320)
                    .onSubmit { model.saveClientID() }
                Button("Save") { model.saveClientID() }
                    .disabled(model.clientIDInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// Live countdown to when Spotify said we may retry. Spotify doesn't publish
// exact limits (throttling is over a rolling 30s window), but a 429 does tell
// us the wait — so we show that rather than a fake "% of limit" gauge.
struct RateLimitBanner: View {
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, until.timeIntervalSince(context.date))
            HStack {
                Image(systemName: "clock.badge.exclamationmark.fill")
                if remaining > 0 {
                    Text("Spotify rate limit reached — try again in \(Self.format(remaining)).")
                } else {
                    Text("Spotify rate limit should be clear now — try again.")
                }
                Spacer()
            }
            .padding(8)
            .background(Color.orange.opacity(0.12))
            .foregroundStyle(.orange)
        }
        .help("Spotify doesn't publish exact limits; it throttles over a rolling 30-second window and tells us when to retry.")
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m \(sec)s" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}
