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
        List {
            statsSection
            if !plan.removals.isEmpty {
                Section("Remove — \(plan.removals.count) to unlike") {
                    ForEach(plan.removals) { r in
                        CardRow(entryID: r.id, card: r.card, reason: r.reason, accent: .red)
                    }
                }
            }
            if !plan.replacements.isEmpty {
                Section("Replace — \(plan.replacements.count) unplayable") {
                    ForEach(plan.replacements) { rep in
                        ReplacementRow(entryID: rep.id, replacement: rep)
                    }
                }
            }
            if !plan.additions.isEmpty {
                Section("Add — \(plan.additions.count) to complete albums") {
                    ForEach(plan.additions) { a in
                        CardRow(entryID: a.id, card: a.card, reason: a.reason, accent: .green)
                    }
                }
            }
        }
    }

    private var statsSection: some View {
        Section {
            let order = [("liked_tracks_scanned", "scanned"), ("duplicates_removed", "duplicates"),
                         ("unplayable_removed", "unplayable"), ("unplayable_replaced", "replaced"),
                         ("additions_suggested", "additions"), ("albums_kept", "albums")]
            HStack(spacing: 18) {
                ForEach(order, id: \.0) { key, label in
                    VStack {
                        Text("\(plan.stats[key] ?? 0)").font(.title3.monospacedDigit().bold())
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Rows

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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if card.explicit { ExplicitTag() }
                    Text("\(card.artist) — \(card.title)").fontWeight(.medium).lineLimit(1)
                }
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(card.durationSeconds)s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            SpotifyLink(url: card.url)
        }
        .padding(.vertical, 2)
        .opacity(model.included(entryID) ? 1 : 0.4)
        .listRowBackground(accent.opacity(0.045))
    }
}

struct ReplacementRow: View {
    @EnvironmentObject var model: AppModel
    let entryID: UUID
    let replacement: Plan.Replacement

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: model.binding(entryID)).labelsHidden()
            VStack(alignment: .leading, spacing: 6) {
                line(card: replacement.dead, symbol: "xmark.circle.fill", color: .red)
                line(card: replacement.alternative, symbol: "checkmark.circle.fill", color: .green)
                Text(replacement.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .opacity(model.included(entryID) ? 1 : 0.4)
        .listRowBackground(Color.orange.opacity(0.05))
    }

    private func line(card: Card, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Artwork(url: card.image)
            if card.explicit { ExplicitTag() }
            Text("\(card.artist) — \(card.title)").lineLimit(1)
            Spacer()
            SpotifyLink(url: card.url)
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
    let url: String?
    var body: some View {
        if let url, let link = URL(string: url) {
            Link(destination: link) { Image(systemName: "arrow.up.right.square") }
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
