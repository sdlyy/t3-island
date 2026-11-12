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
    /// T3's threads as shown, before the island's own changes.
    private var raw: [T3Thread] = []
    private var changes: [String: (change: ThreadChange, at: Date)] = [:]
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
            return apply(snap)
        }
        guard !inFlight else { return }
        inFlight = true
        let reader = reader
        queue.async {
            let snap = reader.snapshot()
            DispatchQueue.main.async { [weak self] in
                self?.inFlight = false
                self?.apply(snap)
            }
        }
    }

    private func apply(_ snap: Snapshot) {
        if heldBy == nil {
            raw = snap.threads
            publishThreads(motion: Theme.shuffle)
        }
        if providers != snap.providers { providers = snap.providers }
        if problem != snap.problem { problem = snap.problem }
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

    /// Forgets the island's sign-in and revokes it in T3.
    func signOut() {
        Task { await actions.signOut() }
    }

    private func perform(_ thread: T3Thread, _ change: ThreadChange, notice text: String, undoable: Bool = true) {
        let index = threads.firstIndex { $0.id == thread.id } ?? 0
        if heldBy == thread.id { heldBy = nil }
        changes[thread.id] = (change, Date())
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
            } catch {
                if changes[thread.id]?.change == change { changes[thread.id] = nil }
                publishThreads(motion: Theme.act)
                let failure = error as? T3Actions.Failure
                if failure?.signedOut == true { onSignedOut() }
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

    /// T3's threads with the island's own changes on top, until T3 shows them or they time out.
    private func publishThreads(motion: Animation) {
        let byId = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        changes = changes.filter { id, entry in
            if demo != nil { return true }
            guard Date().timeIntervalSince(entry.at) < 20 else { return false }
            switch entry.change {
            case .settled: return byId[id] != nil
            case .unsettled: return byId[id] == nil
            case .snoozed: return byId[id]?.snoozedUntil == nil
            case .woke: return byId[id]?.snoozedUntil != nil
            }
        }

        var list = raw
        for (id, entry) in changes {
            switch entry.change {
            case .settled:
                list.removeAll { $0.id == id }
            case .unsettled(let thread, let index):
                if !list.contains(where: { $0.id == id }) { list.insert(thread, at: min(index, list.count)) }
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
