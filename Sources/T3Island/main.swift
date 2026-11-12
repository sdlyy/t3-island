import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let flag = args.firstIndex(of: "--snapshot") {
        PreviewRenderer.write(to: URL(fileURLWithPath: args.indices.contains(flag + 1) ? args[flag + 1] : "snapshots"))
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let settings = SettingsStore()
    private var island: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        island = IslandController(store: store, settings: settings)
    }
}
