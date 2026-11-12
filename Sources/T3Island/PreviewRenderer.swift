import AppKit
import SwiftUI

/// `T3Island --snapshot <dir> [--demo]` renders the island to PNGs without showing a window,
/// from live T3 data or, with `--demo`, from made-up threads and default settings (the README shots).
@MainActor
enum PreviewRenderer {
    static func write(to dir: URL, demo: Bool) {
        let store = Store(demo: demo)
        store.wantsLines = true
        store.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = SettingsStore(value: demo ? IslandSettings() : nil)

        let plain = NotchMetrics(width: 0, height: 24, hasNotch: false)
        let notched = NotchMetrics(width: 185, height: 32, hasNotch: true)
        for (name, expanded, notch) in [
            ("compact", false, plain), ("compact-notch", false, notched),
            ("expanded", true, plain), ("expanded-notch", true, notched),
        ] {
            let state = IslandState()
            state.expanded = expanded
            state.notch = notch
            let shot = IslandView(store: store, state: state, onToggle: {}, onOpen: { _ in }, onSettings: {})
                .padding(.bottom, expanded ? 56 : 40)
                .frame(width: 820)
                .background(Desktop(notch: notch))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .environmentObject(settings)
            save(shot, to: dir.appendingPathComponent("\(name).png"))
        }

        let moods: [ThreadMood] = [.needsYou, .failed, .replied, .idle, .working, .waiting]
        let gallery = VStack(alignment: .leading, spacing: 10) {
            ForEach(moods, id: \.self) { mood in
                HStack(spacing: 12) {
                    Text(mood.label).font(.system(size: 11)).foregroundStyle(.white).frame(width: 70, alignment: .leading)
                    ForEach(0..<8) { i in BlobAvatar(seed: "sample-\(i)", mood: mood, size: 36) }
                }
            }
        }
        .padding(16)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        save(gallery, to: dir.appendingPathComponent("avatars.png"))
    }

    private static func save<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.usesAppKitViews, false))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return print("Could not render \(url.lastPathComponent)") }
        try? png.write(to: url)
        print("Wrote \(url.path)")
    }
}

/// A made-up desktop behind the shots: a wallpaper and a menu bar for the island to hang from.
private struct Desktop: View {
    let notch: NotchMetrics

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: "#15173A")
            RadialGradient(colors: [Color(hex: "#7B4BE0"), .clear], center: UnitPoint(x: 0.1, y: 0.05),
                           startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(hex: "#1FB5A8").opacity(0.6), .clear], center: UnitPoint(x: 0.85, y: 0.1),
                           startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Color(hex: "#F2845C"), .clear], center: UnitPoint(x: 0.95, y: 1),
                           startRadius: 0, endRadius: 560)
            HStack(spacing: 18) {
                Text("Finder").fontWeight(.bold)
                Text("File")
                Text("Edit")
                Spacer()
                Image(systemName: "battery.75percent")
                Text("Thu 12 Nov  9:41")
            }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: notch.height)
            .background(Color.black.opacity(0.2))
        }
    }
}
