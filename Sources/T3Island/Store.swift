import AppKit
import Combine
import SwiftUI

/// A change made from the island. It shows right away and holds until T3's database catches up.
enum ThreadChange: Equatable {
    case settled
    /// Brings a settled thread back, at the place it had in the list.
    case unsettled(T3Thread, index: Int)
    case snoozed(until: Date)
    case woke
}

/// The footer line after an action: what happened, with Undo, or why it failed.
struct ActionNotice: Equatable, Identifiable {
    let id = UUID()
    let text: String
    var isError = false
    /// The thread as it was and the change to reverse; nil once undone or for errors.
    var undo: (thread: T3Thread, change: ThreadChange, index: Int)?

    static func == (a: ActionNotice, b: ActionNotice) -> Bool { a.id == b.id }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var threads: [T3Thread] = []
    @Published private(set) var providers: [ProviderLimits] = []
    @Published private(set) var problem: String?
    @Published private(set) var notice: ActionNotice?
    /// How the next thread list change animates: quick for your own actions, the shuffle for T3's updates.
    private(set) var motion = Theme.shuffle
    /// Called when T3 rejects the island's sign-in, so actions can be turned off.
    var onSignedOut: () -> Void = {}

    private let reader = T3Reader()
    private let actions = T3Actions()
    private let queue = DispatchQueue(label: "t3island.reader", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var demo: DemoData?
    /// T3's threads as shown, before the island's own changes, and when they were read.
    private var raw: [T3Thread] = []
    private var rawAt = Date.distantPast
    /// The island's own changes. `done` is when T3 accepted one; only a snapshot read after that can confirm it.
    private var changes: [String: (change: ThreadChange, at: Date, done: Date?)] = [:]
    /// The row under the pointer. T3's updates wait while it's set, so rows don't move under a click,
    /// and land on the next refresh after it clears, not in the middle of an action.
    private var heldBy: String?

    init(demo: Bool = false) {
        self.demo = demo ? DemoData() : nil
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        if let snap = demo?.next() {
            return apply(snap, readAt: Date())
        }
        guard !inFlight else { return }
        inFlight = true
        let reader = reader
        let readAt = Date()
        queue.async {
            let snap = reader.snapshot()
            DispatchQueue.main.async { [weak self] in
                self?.inFlight = false
                self?.apply(snap, readAt: readAt)
            }
        }
    }

    private func apply(_ snap: Snapshot, readAt: Date) {
        if heldBy == nil || Self.sameLayout(raw, snap.threads) {
            raw = snap.threads
            rawAt = readAt
            publishThreads(motion: Theme.shuffle, prune: true)
        } else if let id = heldBy, let i = raw.firstIndex(where: { $0.id == id }),
                  let fresh = snap.threads.first(where: { $0.id == id }), Self.section(fresh) == Self.section(raw[i]) {
            // The rows stay put, but the one under the pointer still shows what changed, such as a new question.
            raw[i] = fresh
            publishThreads(motion: Theme.shuffle)
        }
        if providers != snap.providers { providers = snap.providers }
        if problem != snap.problem { problem = snap.problem }
    }

    /// Whether T3's copy of a thread (nil when it's not listed) already shows a change.
    private static func shows(_ change: ThreadChange, _ thread: T3Thread?) -> Bool {
        switch change {
        case .settled: thread == nil
        case .unsettled: thread != nil
        case .snoozed: thread?.snoozedUntil != nil
        case .woke: thread?.snoozedUntil == nil
        }
    }

    /// The dropdown section a thread sits in: working, waiting on you or snoozed.
    private static func section(_ thread: T3Thread) -> Int {
        thread.mood == .working ? 0 : thread.snoozedUntil == nil ? 1 : 2
    }

    /// Same rows in the same order and sections, so an update changes what rows say but moves none of them.
    private static func sameLayout(_ a: [T3Thread], _ b: [T3Thread]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && section($0) == section($1) }
    }

    // MARK: Actions

    func settle(_ thread: T3Thread) {
        perform(thread, .settled, notice: "Settled")
    }

    func snooze(_ thread: T3Thread, until: Date) {
        perform(thread, .snoozed(until: until), notice: "Snoozed until \(Format.clock(until, now: Date()))")
    }

    func wake(_ thread: T3Thread) {
        perform(thread, .woke, notice: "Back in your inbox")
    }

    func undo() {
        guard let undo = notice?.undo else { return }
        let reverse: ThreadChange
        switch undo.change {
        case .settled: reverse = .unsettled(undo.thread, index: undo.index)
        case .snoozed: reverse = .woke
        case .woke: reverse = .snoozed(until: undo.thread.snoozedUntil ?? Date().addingTimeInterval(3600))
        case .unsettled: reverse = .settled
        }
        perform(undo.thread, reverse, notice: "Undone", undoable: false)
    }

    func hold(_ threadId: String, _ hold: Bool) {
        if hold {
            heldBy = threadId
        } else if heldBy == threadId {
            heldBy = nil
        }
    }

    /// Forgets the island's sign-in and revokes it in T3. A pending Undo goes too, since it would sign in again.
    func signOut() {
        notice = nil
        Task { await actions.signOut() }
    }

    /// Lets actions sign in again, after a sign-out by the user or by T3.
    func enableActions() {
        Task { await actions.enable() }
    }

    private func perform(_ thread: T3Thread, _ change: ThreadChange, notice text: String, undoable: Bool = true) {
        let index = raw.firstIndex { $0.id == thread.id } ?? 0
        if heldBy == thread.id { heldBy = nil }
        changes[thread.id] = (change, Date(), nil)
        publishThreads(motion: Theme.act)
        let notice = ActionNotice(text: text, undo: undoable ? (thread, change, index) : nil)
        show(notice)
        guard demo == nil else { return }

        Task {
            do {
                switch change {
                case .settled: try await actions.organize(thread.id, .settle)
                case .unsettled: try await actions.organize(thread.id, .unsettle)
                case .snoozed(let until): try await actions.organize(thread.id, .snooze, until: until)
                case .woke: try await actions.organize(thread.id, .unsnooze)
                }
                if changes[thread.id]?.change == change { changes[thread.id]?.done = Date() }
            } catch {
                if changes[thread.id]?.change == change { changes[thread.id] = nil }
                publishThreads(motion: Theme.act)
                let failure = error as? T3Actions.Failure
                if failure?.signedOut == true { onSignedOut() }
                // Keep the notice that said why actions went off, rather than covering it.
                if failure?.actionsOff == true { return }
                show(ActionNotice(text: failure?.signedOut == true
                    ? "T3 signed the island out, so actions are off. Turn them on in Settings to sign in again."
                    : "Couldn't do that: \(error.localizedDescription)", isError: true))
            }
        }
    }

    private func show(_ notice: ActionNotice) {
        self.notice = notice
        Task {
            try? await Task.sleep(nanoseconds: notice.isError ? 8_000_000_000 : 6_000_000_000)
            if self.notice?.id == notice.id { self.notice = nil }
        }
    }

    /// T3's threads with the island's own changes on top, until a snapshot read after T3 accepted a change
    /// shows it, or it times out. Only a fresh snapshot (`prune`) can retire a change: the stale one kept
    /// while a row is held would bring a settled thread back under the pointer.
    private func publishThreads(motion: Animation, prune: Bool = false) {
        let byId = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if prune && demo == nil {
            changes = changes.filter { id, entry in
                // Before T3 answers, the wait can include signing in, so it gets longer.
                guard Date().timeIntervalSince(entry.done ?? entry.at) < (entry.done == nil ? 60 : 20) else { return false }
                guard let done = entry.done, rawAt > done else { return true }
                return !Self.shows(entry.change, byId[id])
            }
        }

        // Restored threads go back first, since their places are counted in T3's list.
        var list = raw
        let restored = changes.values.compactMap { entry -> (thread: T3Thread, index: Int)? in
            guard case .unsettled(let thread, let index) = entry.change, byId[thread.id] == nil else { return nil }
            return (thread, index)
        }
        for item in restored.sorted(by: { $0.index < $1.index }) {
            list.insert(item.thread, at: min(item.index, list.count))
        }
        for (id, entry) in changes {
            switch entry.change {
            case .settled:
                list.removeAll { $0.id == id }
            case .unsettled:
                break
            case .snoozed(let until):
                if let i = list.firstIndex(where: { $0.id == id }) { list[i].snoozedUntil = until }
            case .woke:
                if let i = list.firstIndex(where: { $0.id == id }) { list[i].snoozedUntil = nil }
            }
        }
        if threads != list {
            self.motion = motion
            threads = list
        }
    }

    /// Opens the thread in T3, or just T3 when there is no thread.
    func open(_ thread: T3Thread?) {
        guard demo == nil else { return }
        if let thread, let url = reader.threadURL(thread.id) { NSWorkspace.shared.open(url) } else { openT3() }
    }

    func openT3() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
