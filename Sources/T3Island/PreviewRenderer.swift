import AppKit
import SwiftUI

/// `T3Island --snapshot <dir>` renders the island with live T3 data to PNGs, without showing a window.
@MainActor
enum PreviewRenderer {
    static func write(to dir: URL) {
        let store = Store()
        store.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plain = NotchMetrics(width: 0, height: 24, hasNotch: false)
        let notched = NotchMetrics(width: 185, height: 32, hasNotch: true)
        for (name, expanded, notch) in [
            ("compact", false, plain), ("compact-notch", false, notched),
            ("expanded", true, plain), ("expanded-notch", true, notched),
        ] {
            let state = IslandState()
            state.expanded = expanded
            state.notch = notch
            let island = ZStack(alignment: .top) {
                Color(white: 0.9)
                Color(white: 0.78).frame(height: notch.height)
                IslandView(store: store, state: state, onToggle: {}, onOpen: { _ in }, onSettings: {})
            }
            .environmentObject(SettingsStore())
            .frame(width: 520, height: expanded ? 680 : 56)
            save(island, to: dir.appendingPathComponent("\(name).png"))
        }

        let moods: [ThreadMood] = [.needsYou, .failed, .replied, .idle, .working]
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
