import SwiftUI
import SanitizerKit

@MainActor
final class AppModel: ObservableObject {
    @Published var loggedIn = Engine.loggedIn()
    @Published var clientIDSet = Engine.clientIDIsSet()
    @Published var plan: Plan?
    @Published var busy: String?          // non-nil = a label for the spinner
    @Published var progress: ScanProgress?
    @Published var error: String?
    @Published var notice: String?
    @Published var rateLimitedUntil: Date?   // when Spotify says we may retry
    @Published var findAlternatives = false
    @Published var clientIDInput = ""
    @Published var excluded: Set<UUID> = []   // entries the user unticked
    @Published var lastLog: URL?
    @Published var scannedAt: Date?           // when the shown plan was built

    init() {
        lastLog = Engine.latestLog
        // --demo: load a fixture plan (no network) for UI work across restarts.
        if CommandLine.arguments.contains("--demo") {
            loggedIn = true
            clientIDSet = true
            plan = Engine.samplePlan()
            scannedAt = Date()
            return
        }
        // Reload the last scan so it survives a restart (and isn't re-fetched).
        if let cached = Engine.cachedPlan() {
            plan = cached.plan
            scannedAt = cached.scannedAt
        }
    }

    var isBusy: Bool { busy != nil }

    // MARK: selection

    func included(_ id: UUID) -> Bool { !excluded.contains(id) }

    func allIncluded(_ ids: [UUID]) -> Bool { ids.allSatisfy { !excluded.contains($0) } }

    func setIncluded(_ ids: [UUID], _ include: Bool) {
        if include { excluded.subtract(ids) } else { excluded.formUnion(ids) }
    }

    func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.included(id) ?? true },
                set: { [weak self] keep in
                    guard let self else { return }
                    if keep { self.excluded.remove(id) } else { self.excluded.insert(id) }
                })
    }

    // Selected remove/add ids derived from the plan minus unticked entries.
    func selectedIDs() -> (remove: [String], add: [String]) {
        guard let plan else { return ([], []) }
        var remove: [String] = [], add: [String] = []
        for r in plan.removals where included(r.id) { remove.append(r.card.id) }
        for rep in plan.replacements where included(rep.id) {
            remove.append(rep.dead.id); add.append(rep.alternative.id)
        }
        for completion in plan.completions {
            for track in completion.missing where included(track.id) { add.append(track.card.id) }
        }
        return (remove, add)
    }

    var selectedCounts: (unlike: Int, like: Int) {
        let s = selectedIDs(); return (s.remove.count, s.add.count)
    }

    // MARK: actions

    func saveClientID() {
        let id = clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        Engine.saveClientID(id)
        clientIDSet = Engine.clientIDIsSet()
        clientIDInput = ""
    }

    func login() async {
        await run("Authorizing in your browser…") {
            try await Engine.login()
            self.loggedIn = true
            self.clientIDSet = true
            self.notice = "Logged in."
        }
    }

    func scan() async {
        await run("Scanning your library…") {
            let plan = try await Engine.scan(findAlternatives: self.findAlternatives) { p in
                Task { @MainActor in self.progress = p }
            }
            self.plan = plan
            self.excluded = []
            self.scannedAt = Date()
            Engine.cachePlan(plan)
            self.notice = plan.isEmpty ? "Nothing to do — your library is already spotless." : nil
        }
    }

    func apply() async {
        let ids = selectedIDs()
        await run("Applying changes…") {
            let log = try await Engine.apply(removeIDs: ids.remove, addIDs: ids.add)
            self.lastLog = log
            self.notice = "Applied: \(ids.remove.count) unliked, \(ids.add.count) liked."
            self.plan = nil
            self.scannedAt = nil
            Engine.clearCachedPlan()   // the plan no longer matches the library
        }
    }

    func undo() async {
        guard let log = lastLog else { return }
        await run("Undoing the last apply…") {
            let r = try await Engine.undo(logURL: log)
            self.notice = "Undone: \(r.reliked) re-liked, \(r.unliked) unliked."
            self.lastLog = nil
        }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) async {
        busy = label
        error = nil
        notice = nil
        rateLimitedUntil = nil
        do { try await work() }
        catch let api as ApiError {
            if case .rateLimited(let seconds) = api {
                self.rateLimitedUntil = Date().addingTimeInterval(Double(seconds))
            } else { self.error = api.errorDescription }
        }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        busy = nil
        progress = nil
    }
}
