import SwiftUI

/// A black tab hanging from the top edge: concave "shoulders" where it meets the screen edge,
/// rounded bottom corners. Both radii animate, so the compact tab morphs into the expanded panel.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulder) }
        set { bottomRadius = newValue.first; shoulder = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 4, rect.height / 2))
        let r = max(0, min(bottomRadius, (rect.width - 2 * s) / 2, rect.height - s))
        let left = rect.minX + s, right = rect.maxX - s

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: s)
        p.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: left, y: rect.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left, y: rect.minY), radius: r)
        p.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: s)
        p.closeSubpath()
        return p
    }
}
