import SwiftUI
import AppKit
import SanitizerKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmApply = false

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
                Toggle("Find alternatives", isOn: $model.findAlternatives)
                    .toggleStyle(.checkbox)
                    .help("For unplayable tracks, find the same recording (ISRC) on a playable release")
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

// MARK: - Plan list

struct PlanView: View {
    @EnvironmentObject var model: AppModel
    let plan: Plan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statsHeader
                if !plan.removals.isEmpty {
                    section("Remove — \(plan.removals.count) to unlike",
                            ids: plan.removals.map(\.id), minWidth: 340) {
                        ForEach(plan.removals) { r in
                            CardRow(entryID: r.id, card: r.card, reason: r.reason, accent: .red)
                        }
                    }
                }
                if !plan.replacements.isEmpty {
                    section("Replace — \(plan.replacements.count) unplayable",
                            ids: plan.replacements.map(\.id), minWidth: 360) {
                        ForEach(plan.replacements) { rep in
                            ReplacementRow(entryID: rep.id, replacement: rep)
                        }
                    }
                }
                if !plan.completions.isEmpty {
                    section("Add — \(plan.additionsCount) to complete albums",
                            ids: plan.completions.flatMap { $0.missing.map(\.id) }, minWidth: 360) {
                        ForEach(plan.completions) { completion in
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
    private func section<Content: View>(_ title: String, ids: [UUID], minWidth: CGFloat,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, ids: ids)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10, alignment: .top)], spacing: 10) {
                content()
            }
        }
    }

    private var statsHeader: some View {
        let order = [("liked_tracks_scanned", "scanned"), ("duplicates_removed", "duplicates"),
                     ("unplayable_removed", "unplayable"), ("unplayable_replaced", "replaced"),
                     ("additions_suggested", "additions"), ("albums_kept", "albums")]
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

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            let allOn = model.allIncluded(ids)
            Button(allOn ? "Select none" : "Select all") {
                model.setIncluded(ids, !allOn)
            }
            .font(.caption).textCase(nil).buttonStyle(.borderless)
        }
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

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: model.binding(entryID)).labelsHidden()
            Artwork(url: card.image)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if card.explicit { ExplicitTag() }
                    Text(card.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(card.durationFormatted).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            SpotifyLink(card: card)
        }
        .opacity(model.included(entryID) ? 1 : 0.4)
        .cell(accent)
    }
}

// One partially-liked album: cover + ratio header, then the full tracklist with
// missing tracks tickable and already-liked tracks shown for context.
struct AlbumCompletionView: View {
    let completion: Plan.AlbumCompletion

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
                Toggle("", isOn: model.binding(track.id)).labelsHidden()
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
    }
}

struct ReplacementRow: View {
    @EnvironmentObject var model: AppModel
    let entryID: UUID
    let replacement: Plan.Replacement

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: model.binding(entryID)).labelsHidden()
            VStack(alignment: .leading, spacing: 6) {
                line(replacement.dead, symbol: "xmark.circle.fill", color: .red)
                line(replacement.alternative, symbol: "checkmark.circle.fill", color: .green)
                Text(replacement.reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .opacity(model.included(entryID) ? 1 : 0.4)
        .cell(.orange)
    }

    private func line(_ card: Card, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Artwork(url: card.image)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if card.explicit { ExplicitTag() }
                    Text(card.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            SpotifyLink(card: card)
        }
    }
}

struct ExplicitTag: View {
    var body: some View {
        Text("E").font(.caption2.bold())
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.secondary.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 3))
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
