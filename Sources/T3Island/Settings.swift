import AppKit
import ServiceManagement
import SwiftUI

/// Sections of the expanded island that can be collapsed.
enum IslandSection: String, Codable {
    case limits, waiting, working, snoozed
}

/// Which limit window the collapsed island shows per provider.
enum IslandWindow: String, Codable, CaseIterable {
    case session, weekly, tightest

    var title: String {
        switch self {
        case .session: "5-hour window"
        case .weekly: "Weekly window"
        case .tightest: "Whichever is lowest"
        }
    }

    /// T3's window kind to pick, or nil for the tightest of all.
    var kind: String? { self == .tightest ? nil : rawValue }
}

/// Everything the user can change. Saved as one JSON blob in UserDefaults.
struct IslandSettings: Codable, Equatable {
    var showQuotaLeft = true
    var warnAt = 40
    var criticalAt = 15
    var hiddenProviders: Set<String> = []
    var showWorking = true
    var showWaiting = true
    var showIdle = true
    var facesPerGroup = 3
    var openOnHover = false
    var islandWindow = IslandWindow.session
    var collapsedSections: Set<IslandSection> = [.snoozed]

    /// The number to show for a quota with `left` percent remaining.
    func shown(_ left: Double) -> Double { showQuotaLeft ? left : 100 - left }
    var quotaWord: String { showQuotaLeft ? "left" : "used" }

    /// Colours always follow the quota left, whichever way it is shown.
    func level(_ left: Double) -> Color {
        left <= Double(criticalAt) ? Theme.failed : left <= Double(warnAt) ? Theme.needsYou : Theme.working
    }

    func visible(_ providers: [ProviderLimits]) -> [ProviderLimits] {
        providers.filter { !hiddenProviders.contains($0.id) }
    }

    /// Snoozed threads stay out until they wake, as in T3's sidebar; working ones are shown either way.
    func visible(_ threads: [T3Thread]) -> [T3Thread] {
        threads.filter { ($0.snoozedUntil == nil || $0.mood == .working) && (showIdle || $0.mood != .idle) }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "settings"

    @Published var value: IslandSettings {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: Self.key) }
    }

    /// Pass `value` to use it instead of what's saved; it is only saved once changed.
    init(value: IslandSettings? = nil) {
        self.value = value ?? Self.load()
    }

    /// Overlays what was saved on the defaults, so settings added in later versions don't reset the rest.
    private static func load() -> IslandSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(IslandSettings())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new }),
              let value = try? JSONDecoder().decode(IslandSettings.self, from: merged)
        else { return IslandSettings() }
        return value
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(settings: SettingsStore, store: Store) {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(settings: settings, store: store))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.title = "T3 Island Settings"
            window.isReleasedWhenClosed = false
            window.setContentSize(controller.view.fittingSize)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        // Island clicks don't activate the app, so macOS may refuse the activation above; order front anyway.
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        Form {
            Section("Limits") {
                Picker("Collapsed island shows", selection: $settings.value.islandWindow) {
                    ForEach(IslandWindow.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Show", selection: $settings.value.showQuotaLeft) {
                    Text("Quota left").tag(true)
                    Text("Quota used").tag(false)
                }
                .pickerStyle(.segmented)
                Stepper("Warn at \(settings.value.warnAt)% left", value: $settings.value.warnAt,
                        in: max(5, settings.value.criticalAt)...95, step: 5)
                Stepper("Critical at \(settings.value.criticalAt)% left", value: $settings.value.criticalAt,
                        in: 0...settings.value.warnAt, step: 5)
                ForEach(store.providers) { provider in
                    Toggle("Show \(provider.name)", isOn: providerShown(provider.id))
                }
            }

            Section("Threads") {
                Toggle("Threads waiting on you", isOn: $settings.value.showWaiting)
                Toggle(isOn: $settings.value.showIdle) {
                    Text("Idle threads")
                    Text("Finished threads you haven't settled in T3")
                }
                Toggle("Working threads", isOn: $settings.value.showWorking)
                Stepper("Faces per group: \(settings.value.facesPerGroup)",
                        value: $settings.value.facesPerGroup, in: 1...6)
            }

            Section("Behaviour") {
                Toggle("Open on hover", isOn: $settings.value.openOnHover)
                Toggle(isOn: loginItem) {
                    Text("Launch at login")
                    if let loginNote { Text(loginNote) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func providerShown(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.value.hiddenProviders.contains(id) },
            set: { shown in
                if shown { settings.value.hiddenProviders.remove(id) } else { settings.value.hiddenProviders.insert(id) }
            }
        )
    }

    private var loginItem: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { on in
                let service = SMAppService.mainApp
                do {
                    if on { try service.register() } else { try service.unregister() }
                    loginNote = nil
                } catch {
                    loginNote = error.localizedDescription
                }
                if service.status == .requiresApproval {
                    loginNote = "Approve it in System Settings → General → Login Items."
                }
                launchAtLogin = service.status == .enabled
            }
        )
    }
}
