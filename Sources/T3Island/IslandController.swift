import AppKit
import Combine
import SwiftUI

/// Owns the islands, one per display the settings pick: places each over the notch (or menu bar centre),
/// and makes them click-through everywhere except the island itself.
@MainActor
final class IslandController: NSObject {
    private let store: Store
    private let settings: SettingsStore
    private let settingsWindow = SettingsWindow()
    private var islands: [CGDirectDisplayID: Island] = [:]
    private var monitors: [Any] = []
    private var displayChange: AnyCancellable?

    /// Big enough for the expanded island plus its shadow; the transparent rest ignores the mouse.
    private static let panelSize = CGSize(width: IslandView.expandedWidth + 80, height: 720)

    init(store: Store, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        super.init()

        placeIslands(on: settings.value.display)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // @Published sends the new value before it's stored, so it's passed along rather than read back.
        displayChange = settings.$value.map(\.display).removeDuplicates().dropFirst()
            .sink { [weak self] display in self?.placeIslands(on: display) }
        installMouseMonitors()
    }

    // MARK: Placement

    @objc private func screensChanged() { placeIslands(on: settings.value.display) }

    private func placeIslands(on display: IslandDisplay) {
        let screens = display.screens()
        let ids = Set(screens.map(\.displayID))
        for (id, island) in islands where !ids.contains(id) {
            island.cancelPending()
            island.panel.orderOut(nil)
            islands[id] = nil
        }
        for screen in screens {
            let island = islands[screen.displayID] ?? makeIsland()
            islands[screen.displayID] = island
            place(island, on: screen)
            island.panel.orderFrontRegardless()
        }
        store.wantsLines = islands.values.contains { $0.state.expanded }
    }

    private func makeIsland() -> Island {
        let island = Island()
        let root = IslandView(
            store: store,
            state: island.state,
            onToggle: { [weak self, weak island] in
                guard let self, let island else { return }
                setExpanded(island, !island.state.expanded)
            },
            onOpen: { [weak self, weak island] thread in
                guard let self, let island else { return }
                store.open(thread)
                setExpanded(island, false)
            },
            onSettings: { [weak self, weak island] in
                guard let self, let island else { return }
                setExpanded(island, false)
                settingsWindow.show(settings: settings, store: store, on: island.panel.screen)
            }
        )
        let host = IslandHostingView(rootView: root.environmentObject(settings))
        host.sizingOptions = []
        island.panel.contentView = host
        return island
    }

    private func place(_ island: Island, on screen: NSScreen) {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            island.state.notch = NotchMetrics(
                width: frame.width - left.width - right.width,
                height: screen.safeAreaInsets.top,
                hasNotch: true
            )
        } else {
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            island.state.notch = NotchMetrics(
                width: 0,
                height: menuBar >= 20 ? menuBar : NSStatusBar.system.thickness,
                hasNotch: false
            )
        }

        let size = Self.panelSize
        island.panel.setFrame(
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
            MainActor.assumeIsolated { self?.collapseAll() }
        }) { monitors.append(outside) }
    }

    private func trackMouse() {
        for island in islands.values { trackMouse(island) }
    }

    private func collapseAll() {
        for island in islands.values { setExpanded(island, false) }
    }

    private func trackMouse(_ island: Island) {
        let state = island.state, panel = island.panel
        let size = state.shapeSize
        guard size != .zero else { return }
        let frame = panel.frame
        let slop: CGFloat = state.expanded ? 12 : 4
        let shape = CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                           width: size.width, height: size.height)
            .insetBy(dx: -slop, dy: -slop)
        let inside = shape.contains(NSEvent.mouseLocation)

        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if state.hovering != inside {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { state.hovering = inside }
        }

        if state.expanded && !inside {
            if island.collapseWork == nil {
                island.collapseWork = after(0.4) { [weak self, weak island] in
                    if let island { self?.setExpanded(island, false) }
                }
            }
        } else {
            island.collapseWork?.cancel()
            island.collapseWork = nil
        }

        if !state.expanded && inside && settings.value.openOnHover {
            if island.openWork == nil {
                island.openWork = after(0.3) { [weak self, weak island] in
                    if let island { self?.setExpanded(island, true) }
                }
            }
        } else {
            island.openWork?.cancel()
            island.openWork = nil
        }
    }

    private func after(_ seconds: Double, _ action: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return work
    }

    /// Opening one island closes the others, so only one dropdown is open at a time.
    private func setExpanded(_ island: Island, _ expanded: Bool) {
        island.cancelPending()
        guard island.state.expanded != expanded else { return }
        if expanded {
            for other in islands.values where other !== island { setExpanded(other, false) }
        }
        store.wantsLines = expanded
        if expanded { store.refresh() }
        withAnimation(.spring(response: 0.42, dampingFraction: expanded ? 0.78 : 0.88)) {
            island.state.expanded = expanded
        }
    }
}

/// The island on one display, with its own hover and open state.
@MainActor
private final class Island {
    let state = IslandState()
    let panel = IslandPanel()
    var collapseWork: DispatchWorkItem?
    var openWork: DispatchWorkItem?

    func cancelPending() {
        collapseWork?.cancel()
        collapseWork = nil
        openWork?.cancel()
        openWork = nil
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
