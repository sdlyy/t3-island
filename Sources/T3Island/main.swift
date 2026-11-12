import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    let demo = args.contains("--demo")
    if let flag = args.firstIndex(of: "--snapshot") {
        let dir = args.indices.contains(flag + 1) && !args[flag + 1].hasPrefix("--") ? args[flag + 1] : "snapshots"
        PreviewRenderer.write(to: URL(fileURLWithPath: dir), demo: demo)
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate(demo: demo)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: Store
    private let settings = SettingsStore()
    private var island: IslandController?

    init(demo: Bool) {
        store = Store(demo: demo)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onSignedOut = { [settings] in settings.value.threadActions = false }
        store.start()
        island = IslandController(store: store, settings: settings)
    }
}
