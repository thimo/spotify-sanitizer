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
    // Scan options (persisted in UserDefaults).
    @Published var completionThreshold = 0.70 { didSet { ud.set(completionThreshold, forKey: "completionThreshold") } }
    @Published var skitMaxSeconds = 90 { didSet { ud.set(skitMaxSeconds, forKey: "skitMaxSeconds") } }
    @Published var completeAlbums = true { didSet { ud.set(completeAlbums, forKey: "completeAlbums") } }
    @Published var dropUnplayable = true { didSet { ud.set(dropUnplayable, forKey: "dropUnplayable") } }
    @Published var findAlternatives = false { didSet { ud.set(findAlternatives, forKey: "findAlternatives") } }
    @Published var fuzzyAlternatives = false { didSet { ud.set(fuzzyAlternatives, forKey: "fuzzyAlternatives") } }

    @Published var clientIDInput = ""
    @Published var excluded: Set<UUID> = []   // entries the user unticked
    @Published var workingItem: UUID?         // a single item being applied right now
    @Published var lastLog: URL?
    @Published var scannedAt: Date?           // when the shown plan was built

    private let demo = CommandLine.arguments.contains("--demo")
    private let ud = UserDefaults.standard

    init() {
        loadSettings()
        lastLog = Engine.latestLog
        // --demo: load a fixture plan (no network) for UI work across restarts.
        if demo {
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
        rateLimitedUntil = Engine.rateLimitedUntil   // resume a cooldown countdown
    }

    var isBusy: Bool { busy != nil }

    // MARK: selection

    func included(_ id: UUID) -> Bool { !excluded.contains(id) }

    func toggle(_ id: UUID) {
        if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
    }

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

    private func loadSettings() {
        if ud.object(forKey: "completionThreshold") != nil { completionThreshold = ud.double(forKey: "completionThreshold") }
        if ud.object(forKey: "skitMaxSeconds") != nil { skitMaxSeconds = ud.integer(forKey: "skitMaxSeconds") }
        if ud.object(forKey: "completeAlbums") != nil { completeAlbums = ud.bool(forKey: "completeAlbums") }
        if ud.object(forKey: "dropUnplayable") != nil { dropUnplayable = ud.bool(forKey: "dropUnplayable") }
        if ud.object(forKey: "findAlternatives") != nil { findAlternatives = ud.bool(forKey: "findAlternatives") }
        if ud.object(forKey: "fuzzyAlternatives") != nil { fuzzyAlternatives = ud.bool(forKey: "fuzzyAlternatives") }
    }

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

    func logout() {
        Engine.logout()
        loggedIn = false
        notice = "Logged out."
    }

    func scan() async {
        if let until = Engine.rateLimitedUntil {
            rateLimitedUntil = until   // still cooling down — don't fire a doomed request
            return
        }
        await run("Scanning your library…") {
            let plan = try await Engine.scan(
                completionThreshold: self.completionThreshold,
                skitMaxSeconds: self.skitMaxSeconds,
                dropUnplayable: self.dropUnplayable,
                findAlternatives: self.findAlternatives,
                fuzzyAlternatives: self.fuzzyAlternatives,
                completeAlbums: self.completeAlbums
            ) { p in
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
            if self.demo {
                try? await Task.sleep(nanoseconds: 600_000_000)
            } else {
                self.lastLog = try await Engine.apply(removeIDs: ids.remove, addIDs: ids.add)
            }
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

    // MARK: per-item actions (work through the list one at a time)

    func doRemoval(_ removal: Plan.Removal) async {
        await perform(removal.id, remove: [removal.card.id], add: [],
                      done: "Unliked “\(removal.card.title)”") {
            self.plan?.removals.removeAll { $0.id == removal.id }
        }
    }

    func doReplacement(_ replacement: Plan.Replacement) async {
        await perform(replacement.id, remove: [replacement.dead.id], add: [replacement.alternative.id],
                      done: "Replaced “\(replacement.dead.title)”") {
            self.plan?.replacements.removeAll { $0.id == replacement.id }
        }
    }

    // Drop the dead track without adding the alternative.
    func unlikeDead(_ replacement: Plan.Replacement) async {
        await perform(replacement.id, remove: [replacement.dead.id], add: [],
                      done: "Unliked “\(replacement.dead.title)”") {
            self.plan?.replacements.removeAll { $0.id == replacement.id }
        }
    }

    func doCompletion(_ completion: Plan.AlbumCompletion) async {
        let ids = completion.missing.filter { included($0.id) }.map { $0.card.id }
        guard !ids.isEmpty else { return }
        await perform(completion.id, remove: [], add: ids,
                      done: "Added \(ids.count) to “\(completion.album)”") {
            self.plan?.completions.removeAll { $0.id == completion.id }
        }
    }

    private func perform(_ itemID: UUID, remove: [String], add: [String],
                         done: String, mutate: @escaping () -> Void) async {
        workingItem = itemID
        error = nil; notice = nil; rateLimitedUntil = nil
        do {
            if demo {
                try? await Task.sleep(nanoseconds: 400_000_000)   // show the spinner
            } else {
                lastLog = try await Engine.apply(removeIDs: remove, addIDs: add)
            }
            mutate()
            notice = done
            if let plan, !plan.isEmpty {
                Engine.cachePlan(plan, scannedAt: scannedAt ?? Date())
            } else {
                plan = nil; scannedAt = nil; Engine.clearCachedPlan()
            }
        } catch let api as ApiError {
            if case .rateLimited(let seconds) = api { rateLimitedUntil = Date().addingTimeInterval(Double(seconds)) }
            else { error = api.errorDescription }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        workingItem = nil
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
