import AppKit
import Combine

@MainActor
final class Store: ObservableObject {
    @Published private(set) var threads: [T3Thread] = []
    @Published private(set) var providers: [ProviderLimits] = []
    @Published private(set) var problem: String?

    private let reader = T3Reader()
    private let queue = DispatchQueue(label: "t3island.reader", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var demo: DemoData?

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
        if threads != snap.threads { threads = snap.threads }
        if providers != snap.providers { providers = snap.providers }
        if problem != snap.problem { problem = snap.problem }
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
