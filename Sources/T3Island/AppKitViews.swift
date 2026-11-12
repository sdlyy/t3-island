import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Off for offscreen previews: ImageRenderer cannot draw AppKit views.
    var usesAppKitViews: Bool {
        get { self[UsesAppKitViewsKey.self] }
        set { self[UsesAppKitViewsKey.self] = newValue }
    }
}

private struct UsesAppKitViewsKey: EnvironmentKey {
    static let defaultValue = true
}

/// A looping Core Animation layer. It runs in the window server, so a spinning or pulsing avatar
/// costs the app almost nothing, unlike SwiftUI's repeatForever, which re-renders every frame.
struct LoopingLayer: NSViewRepresentable {
    enum Style { case spin, pulse }
    let style: Style
    let color: NSColor
    var lineWidth: CGFloat = 0

    func makeNSView(context: Context) -> LoopingLayerView {
        LoopingLayerView(style: style, color: color, lineWidth: lineWidth)
    }

    func updateNSView(_ view: LoopingLayerView, context: Context) {}
}

final class LoopingLayerView: NSView {
    private let shape = CAShapeLayer()
    private let style: LoopingLayer.Style

    init(style: LoopingLayer.Style, color: NSColor, lineWidth: CGFloat) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)

        let loop: CAAnimation
        switch style {
        case .spin:
            shape.fillColor = nil
            shape.strokeColor = color.withAlphaComponent(0.9).cgColor
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            shape.strokeEnd = 0.3
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1.4
            loop = spin
        case .pulse:
            shape.fillColor = color.cgColor
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.25
            fade.toValue = 0.6
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.94
            grow.toValue = 1.06
            let group = CAAnimationGroup()
            group.animations = [fade, grow]
            group.duration = 0.8
            group.autoreverses = true
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            loop = group
        }
        loop.repeatCount = .infinity
        loop.isRemovedOnCompletion = false
        shape.add(loop, forKey: "loop")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        let inset = shape.lineWidth / 2
        shape.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
    }
}

/// SwiftUI's onHover only fires while the app is active, and the island never activates
/// (it must not steal focus), so rows track the mouse with an always-active tracking area.
struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackerView { HoverTrackerView(onChange: onChange) }
    func updateNSView(_ view: HoverTrackerView, context: Context) { view.onChange = onChange }
}

final class HoverTrackerView: NSView {
    var onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
    /// Clicks go to the SwiftUI button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
