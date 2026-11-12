import SwiftUI

/// A small blob creature per thread. Shape and color come from the thread id; the face shows the mood.
struct BlobAvatar: View {
    let seed: String
    let mood: ThreadMood
    var size: CGFloat = 20
    /// Greys out a face that needs nothing now, such as a snoozed thread. Working faces always are.
    var muted = false
    @Environment(\.usesAppKitViews) private var animates

    var body: some View {
        // Working threads don't need you, so they recede in grey; everything else stays in full colour.
        let muted = muted || mood == .working
        ZStack {
            switch mood {
            case .working where animates:
                LoopingLayer(style: .spin, color: .white, lineWidth: max(1, size * 0.06))
                    .frame(width: size * 0.96, height: size * 0.96)
            case .working:
                Circle()
                    .trim(from: 0.5, to: 0.8)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: max(1, size * 0.06), lineCap: .round))
                    .frame(width: size * 0.9, height: size * 0.9)
            case _ where muted:
                EmptyView()
            case .needsYou where animates:
                LoopingLayer(style: .pulse, color: NSColor(Theme.needsYou))
                    .frame(width: size * 0.92, height: size * 0.92)
            case .needsYou:
                Circle().fill(Theme.needsYou.opacity(0.45)).frame(width: size * 0.92, height: size * 0.92)
            case .failed:
                Circle().fill(Theme.failed.opacity(0.3)).frame(width: size * 0.92, height: size * 0.92)
            case .replied, .idle:
                EmptyView()
            }
            // Greyed at the source rather than with .saturation, which ImageRenderer drops from snapshots.
            BlobFace(profile: BlobProfile(seed: seed, greyscale: muted), mood: mood)
        }
        .frame(width: size, height: size)
        .opacity(muted ? 0.5 : 1)
    }
}

struct BlobProfile {
    private static let palette: [(base: String, light: String)] = [
        ("#FF6B5E", "#FFA59C"), ("#FF9F43", "#FFC98F"), ("#F7C23C", "#FFE08A"), ("#3DD68C", "#8DF0BE"),
        ("#2CCFC3", "#86ECE4"), ("#4D9DFF", "#9CC8FF"), ("#9B7BFF", "#C7B6FF"), ("#FF6FB5", "#FFADD6"),
    ]

    let base: Color, light: Color
    let lobes: Double, wobble: Double, phase: Double
    let ripples: Double, ripple: Double, ripplePhase: Double
    let aspect: Double, eyeSpread: Double

    init(seed: String, greyscale: Bool = false) {
        var rng = SeededRandom(seed)
        let colors = Self.palette[rng.int(Self.palette.count)]
        base = Color(hex: colors.base, greyscale: greyscale)
        light = Color(hex: colors.light, greyscale: greyscale)
        lobes = [2, 3, 4, 5][rng.int(4)]
        wobble = 0.035 + rng.unit() * 0.05
        phase = rng.unit() * 2 * .pi
        ripples = [5, 6, 7][rng.int(3)]
        ripple = 0.01 + rng.unit() * 0.02
        ripplePhase = rng.unit() * 2 * .pi
        aspect = 0.93 + rng.unit() * 0.14
        eyeSpread = 0.28 + rng.unit() * 0.08
    }
}

private struct BlobFace: View {
    let profile: BlobProfile
    let mood: ThreadMood

    private static let ink = Color(white: 0.07)

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = Double(min(size.width, size.height)) * 0.38
            ctx.fill(
                body(c, r),
                with: .linearGradient(Gradient(colors: [profile.light, profile.base]),
                                      startPoint: CGPoint(x: c.x - r * 0.7, y: c.y - r),
                                      endPoint: CGPoint(x: c.x + r * 0.6, y: c.y + r))
            )

            face(ctx, c, r)
        }
    }

    private func body(_ c: CGPoint, _ r: Double) -> Path {
        var path = Path()
        let steps = 72
        for i in 0...steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let k = 1 + profile.wobble * sin(profile.lobes * a + profile.phase)
                + profile.ripple * sin(profile.ripples * a + profile.ripplePhase)
            let point = CGPoint(x: c.x + r * k * cos(a) * profile.aspect,
                                y: c.y + r * k * sin(a) / profile.aspect)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func face(_ ctx: GraphicsContext, _ c: CGPoint, _ r: Double) {
        let spread = r * profile.eyeSpread
        let eyeY = c.y - r * 0.1
        let w = r * 0.22, h = r * 0.3
        let line = StrokeStyle(lineWidth: max(0.9, r * 0.1), lineCap: .round)
        let mouth = CGPoint(x: c.x, y: c.y + r * 0.36)

        for side in [-1.0, 1.0] {
            let x = c.x + side * spread
            switch mood {
            case .working, .needsYou, .idle:
                let big = mood == .needsYou ? 1.25 : 1
                let look = mood == .working ? r * 0.06 : 0
                let lift = mood == .needsYou ? -r * 0.04 : 0
                let eh = h * big
                let eye = CGRect(x: x + look - w * big / 2, y: eyeY + lift - eh / 2, width: w * big, height: eh)
                ctx.fill(Path(ellipseIn: eye), with: .color(Self.ink))
                let glint = w * 0.26
                ctx.fill(Path(ellipseIn: CGRect(x: eye.midX + w * 0.2 - glint, y: eye.minY + eh * 0.28 - glint,
                                                width: glint * 2, height: glint * 2)),
                         with: .color(.white.opacity(0.9)))
            case .replied:
                var arc = Path()
                arc.move(to: CGPoint(x: x - w * 0.9, y: eyeY + h * 0.2))
                arc.addQuadCurve(to: CGPoint(x: x + w * 0.9, y: eyeY + h * 0.2), control: CGPoint(x: x, y: eyeY - h * 0.9))
                ctx.stroke(arc, with: .color(Self.ink), style: line)
            case .failed:
                var cross = Path()
                let d = w * 0.7
                cross.move(to: CGPoint(x: x - d, y: eyeY - d)); cross.addLine(to: CGPoint(x: x + d, y: eyeY + d))
                cross.move(to: CGPoint(x: x + d, y: eyeY - d)); cross.addLine(to: CGPoint(x: x - d, y: eyeY + d))
                ctx.stroke(cross, with: .color(Self.ink), style: line)
            }
        }

        switch mood {
        case .needsYou:
            ctx.fill(Path(ellipseIn: CGRect(x: mouth.x - r * 0.07, y: mouth.y - r * 0.09, width: r * 0.14, height: r * 0.18)),
                     with: .color(Self.ink))
        case .replied, .failed:
            let dip = mood == .replied ? r * 0.16 : -r * 0.14
            var smile = Path()
            smile.move(to: CGPoint(x: mouth.x - r * 0.15, y: mouth.y))
            smile.addQuadCurve(to: CGPoint(x: mouth.x + r * 0.15, y: mouth.y), control: CGPoint(x: mouth.x, y: mouth.y + dip))
            ctx.stroke(smile, with: .color(Self.ink), style: line)
        case .idle:
            var flat = Path()
            flat.move(to: CGPoint(x: mouth.x - r * 0.12, y: mouth.y))
            flat.addLine(to: CGPoint(x: mouth.x + r * 0.12, y: mouth.y))
            ctx.stroke(flat, with: .color(Self.ink), style: line)
        case .working:
            break
        }
    }
}

/// FNV-1a seed + splitmix64, so a thread keeps the same blob across launches.
struct SeededRandom {
    private var state: UInt64

    init(_ seed: String) {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}
