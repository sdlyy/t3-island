import AppKit
import SwiftUI

/// Owns the island panel: places it over the notch (or menu bar centre), and makes it
/// click-through everywhere except the island itself.
@MainActor
final class IslandController: NSObject {
    private let store: Store
    private let settings: SettingsStore
    private let state = IslandState()
    private let panel = IslandPanel()
    private let settingsWindow = SettingsWindow()
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?

    /// Big enough for the expanded island plus its shadow; the transparent rest ignores the mouse.
    private static let panelSize = CGSize(width: IslandView.expandedWidth + 80, height: 720)

    init(store: Store, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        super.init()

        let root = IslandView(
            store: store,
            state: state,
            onToggle: { [weak self] in
                guard let self else { return }
                setExpanded(!state.expanded)
            },
            onOpen: { [weak self] thread in
                self?.store.open(thread)
                self?.setExpanded(false)
            },
            onSettings: { [weak self] in
                guard let self else { return }
                setExpanded(false)
                settingsWindow.show(settings: settings, store: store)
            }
        )
        let host = IslandHostingView(rootView: root.environmentObject(settings))
        host.sizingOptions = []
        panel.contentView = host

        placePanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        installMouseMonitors()
    }

    // MARK: Placement

    @objc private func screensChanged() { placePanel() }

    private func placePanel() {
        // Prefer the notched built-in display; otherwise the menu bar screen.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
        else { return }
        let frame = screen.frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notch = NotchMetrics(
                width: frame.width - left.width - right.width,
                height: screen.safeAreaInsets.top,
                hasNotch: true
            )
        } else {
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            state.notch = NotchMetrics(
                width: 0,
                height: menuBar >= 20 ? menuBar : NSStatusBar.system.thickness,
                hasNotch: false
            )
        }

        let size = Self.panelSize
        panel.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    // MARK: Mouse

    private func installMouseMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        }) { monitors.append(local) }
        // Clicks in other apps close the expanded island.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.setExpanded(false) }
        }) { monitors.append(outside) }
    }

    private func trackMouse() {
        let size = state.shapeSize
        guard size != .zero else { return }
        let frame = panel.frame
        let slop: CGFloat = state.expanded ? 12 : 4
        let island = CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                            width: size.width, height: size.height)
            .insetBy(dx: -slop, dy: -slop)
        let inside = island.contains(NSEvent.mouseLocation)

        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if state.hovering != inside {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { state.hovering = inside }
        }

        if state.expanded && !inside {
            if collapseWork == nil { collapseWork = after(0.4) { [weak self] in self?.setExpanded(false) } }
        } else {
            collapseWork?.cancel()
            collapseWork = nil
        }

        if !state.expanded && inside && settings.value.openOnHover {
            if openWork == nil { openWork = after(0.3) { [weak self] in self?.setExpanded(true) } }
        } else {
            openWork?.cancel()
            openWork = nil
        }
    }

    private func after(_ seconds: Double, _ action: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return work
    }

    private func setExpanded(_ expanded: Bool) {
        collapseWork?.cancel()
        collapseWork = nil
        openWork?.cancel()
        openWork = nil
        guard state.expanded != expanded else { return }
        store.wantsLines = expanded
        if expanded { store.refresh() }
        withAnimation(.spring(response: 0.42, dampingFraction: expanded ? 0.78 : 0.88)) {
            state.expanded = expanded
        }
    }
}

final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Borderless windows may sit over the menu bar; don't let AppKit push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    /// The panel never becomes key, so the first click must already act.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
