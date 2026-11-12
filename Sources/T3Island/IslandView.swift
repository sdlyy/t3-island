import SwiftUI

struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool
}

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    @Published var notch = NotchMetrics(width: 0, height: 24, hasNotch: false)
    /// Last laid-out size of the island, for hit-testing the mouse in screen space.
    var shapeSize: CGSize = .zero
}

struct IslandView: View {
    @ObservedObject var store: Store
    @ObservedObject var state: IslandState
    let onToggle: () -> Void
    let onOpen: (T3Thread?) -> Void
    let onSettings: () -> Void

    static let expandedWidth: CGFloat = 440
    static let earWidth: CGFloat = 46

    var body: some View {
        let expanded = state.expanded
        let shoulder: CGFloat = expanded ? 14 : 6
        let shape = NotchShape(bottomRadius: expanded ? 22 : 9, shoulder: shoulder)

        VStack(spacing: 0) {
            if expanded {
                ExpandedIsland(store: store, headerHeight: state.notch.height, onOpen: onOpen, onSettings: onSettings)
                    .padding(.horizontal, shoulder + 12)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            .animation(.easeOut(duration: 0.22).delay(0.08)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))
                    ))
            } else {
                CompactIsland(store: store, notch: state.notch, hovering: state.hovering)
                    .padding(.horizontal, shoulder)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .frame(width: expanded ? Self.expandedWidth : nil)
        // Content fading out while the island shrinks must stay inside it, not spill over the screen.
        .clipShape(shape)
        .background(shape.fill(Theme.island).shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 14, y: 4))
        .onGeometryChange(for: CGSize.self, of: \.size) { state.shapeSize = $0 }
        // Thread updates shuffle faces, rows and the island's outline together.
        .animation(Theme.shuffle, value: store.threads)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

// MARK: - Compact

private struct CompactIsland: View {
    @ObservedObject var store: Store
    let notch: NotchMetrics
    let hovering: Bool
    @EnvironmentObject private var settings: SettingsStore
    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0

    var body: some View {
        // Over a notch both ears take the wider one's width so the island stays centred on it;
        // without a notch each ear just fits its content.
        let grow: CGFloat = hovering ? 8 : 0
        let ear: CGFloat? = notch.hasNotch ? max(leftWidth, rightWidth, IslandView.earWidth) + grow : nil

        HStack(spacing: 0) {
            ThreadGlance(threads: settings.value.visible(store.threads), settings: settings.value,
                         size: min(20, notch.height - 6))
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
                    withAnimation(Theme.shuffle) { leftWidth = width }
                }
                .frame(width: ear, alignment: .trailing)
                .padding(.trailing, 6)
            Color.clear.frame(width: notch.hasNotch ? notch.width : 4)
            LimitGlance(providers: settings.value.visible(store.providers), settings: settings.value)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { rightWidth = $0 }
                .frame(width: ear, alignment: .leading)
                .padding(.leading, 6)
        }
        .padding(.horizontal, notch.hasNotch ? 8 : 8 + grow / 2)
        .frame(height: notch.height + (hovering ? 4 : 0))
    }
}

/// Threads waiting on you (questions, failures, replies, idle), then a divider, then the working ones.
private struct ThreadGlance: View {
    let threads: [T3Thread]
    let settings: IslandSettings
    let size: CGFloat
    /// Lets a face slide across when its thread moves between the waiting and working groups.
    @Namespace private var faces

    var body: some View {
        let working = settings.showWorking ? threads.filter { $0.mood == .working } : []
        let waiting = settings.showWaiting ? threads.filter { $0.mood != .working } : []
        HStack(spacing: 6) {
            if working.isEmpty && waiting.isEmpty && (settings.showWorking || settings.showWaiting) {
                BlobAvatar(seed: "t3-island", mood: .idle, size: size, muted: true)
            }
            if !waiting.isEmpty {
                group(waiting)
            }
            if !working.isEmpty && !waiting.isEmpty {
                Capsule().fill(Color.white.opacity(0.22)).frame(width: 1, height: size * 0.6)
            }
            if !working.isEmpty {
                group(working)
            }
        }
    }

    private func group(_ threads: [T3Thread]) -> some View {
        HStack(spacing: 3) {
            HStack(spacing: -size * 0.3) {
                ForEach(threads.prefix(settings.facesPerGroup)) { thread in
                    BlobAvatar(seed: thread.id, mood: thread.mood, size: size)
                        .matchedGeometryEffect(id: thread.id, in: faces)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            if threads.count > settings.facesPerGroup {
                Text("+\(threads.count - settings.facesPerGroup)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .transition(.opacity)
            }
        }
    }
}

/// One ring per provider, in the provider's colour, for the window chosen in settings (5-hour by default).
private struct LimitGlance: View {
    let providers: [ProviderLimits]
    let settings: IslandSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            HStack(spacing: 8) {
                if !providers.isEmpty && providers.allSatisfy({ $0.windows.isEmpty }) {
                    Text("–").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                ForEach(providers) { provider in
                    if let window = provider.tightest(at: now, kind: settings.islandWindow.kind) {
                        let left = window.remaining(at: now)
                        let shown = Int(settings.shown(left).rounded())
                        HStack(spacing: 4) {
                            RingGauge(fraction: settings.shown(left) / 100, color: Theme.accent(provider))
                                .frame(width: 12, height: 12)
                            Text("\(shown)%")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(left <= Double(settings.warnAt) ? settings.level(left) : Theme.primary)
                        }
                        .help("\(provider.name) · \(window.label): \(shown)% \(settings.quotaWord)")
                    }
                }
            }
        }
    }
}

private struct RingGauge: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.4)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Expanded

private struct ExpandedIsland: View {
    @ObservedObject var store: Store
    let headerHeight: CGFloat
    let onOpen: (T3Thread?) -> Void
    let onSettings: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    /// Lets a row slide between sections when its thread changes state.
    @Namespace private var rows

    private static let maxRows = 7
    /// Rows kept for working threads, so a long list of waiting ones can't push them out.
    private static let workingRows = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let now = timeline.date
            let threads = settings.value.visible(store.threads)
            let waiting = settings.value.showWaiting ? threads.filter { $0.mood != .working } : []
            let working = settings.value.showWorking ? threads.filter { $0.mood == .working } : []
            let snoozed = settings.value.showWaiting
                ? store.threads.filter { $0.snoozedUntil != nil && $0.mood != .working } : []
            // Only open sections take rows.
            let openWaiting = isOpen(.waiting) ? waiting.count : 0
            let openWorking = isOpen(.working) ? working.count : 0
            let openSnoozed = isOpen(.snoozed) ? snoozed.count : 0
            let workingShown = min(openWorking, max(Self.workingRows, Self.maxRows - openWaiting))
            let waitingShown = min(openWaiting, Self.maxRows - workingShown)
            let snoozedShown = min(openSnoozed, Self.maxRows - workingShown - waitingShown)
            let hidden = openWaiting + openWorking + openSnoozed - waitingShown - workingShown - snoozedShown
            VStack(alignment: .leading, spacing: 10) {
                header(threads).frame(height: headerHeight)

                if let problem = store.problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.failed)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Limits", isOpen: isOpen(.limits)) { toggle(.limits) }
                    if isOpen(.limits) {
                        LimitsGrid(providers: settings.value.visible(store.providers), settings: settings.value, now: now)
                    }
                }

                Rectangle().fill(Theme.hairline).frame(height: 1)

                VStack(alignment: .leading, spacing: 2) {
                    if waiting.isEmpty && working.isEmpty && snoozed.isEmpty {
                        Text("No open threads")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    if !waiting.isEmpty {
                        SectionHeader(title: "Waiting on you", count: waiting.count, isOpen: isOpen(.waiting)) {
                            toggle(.waiting)
                        }
                        ForEach(waiting.prefix(waitingShown)) { thread in
                            ThreadRow(thread: thread, now: now) { onOpen(thread) }
                                .matchedGeometryEffect(id: thread.id, in: rows)
                        }
                    }
                    if !working.isEmpty {
                        SectionHeader(title: "Working", count: working.count, isOpen: isOpen(.working)) {
                            toggle(.working)
                        }
                        .padding(.top, waiting.isEmpty ? 0 : 6)
                        ForEach(working.prefix(workingShown)) { thread in
                            ThreadRow(thread: thread, now: now) { onOpen(thread) }
                                .matchedGeometryEffect(id: thread.id, in: rows)
                        }
                    }
                    if let wake = snoozed.compactMap(\.snoozedUntil).min() {
                        SectionHeader(title: "Snoozed", count: snoozed.count,
                                      detail: "back in \(Format.duration(wake.timeIntervalSince(now)))",
                                      isOpen: isOpen(.snoozed)) { toggle(.snoozed) }
                            .padding(.top, waiting.isEmpty && working.isEmpty ? 0 : 6)
                        ForEach(snoozed.prefix(snoozedShown)) { thread in
                            ThreadRow(thread: thread, now: now) { onOpen(thread) }
                                .matchedGeometryEffect(id: thread.id, in: rows)
                        }
                    }
                }

                HStack {
                    FooterButton(title: hidden > 0 ? "+\(hidden) more in T3 Code" : "Open T3 Code") { onOpen(nil) }
                    Spacer()
                    FooterButton(title: "Settings", action: onSettings)
                    FooterButton(title: "Quit") { NSApp.terminate(nil) }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func isOpen(_ section: IslandSection) -> Bool {
        !settings.value.collapsedSections.contains(section)
    }

    private func toggle(_ section: IslandSection) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            if isOpen(section) {
                settings.value.collapsedSections.insert(section)
            } else {
                settings.value.collapsedSections.remove(section)
            }
        }
    }

    /// Sits beside the notch (or in the menu bar on Macs without one), so it stays short on both sides.
    private func header(_ threads: [T3Thread]) -> some View {
        HStack(spacing: 10) {
            Text("T3")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.secondary)
            Spacer()
            ForEach([ThreadMood.needsYou, .failed, .replied, .idle, .working], id: \.self) { mood in
                let count = threads.filter { $0.mood == mood }.count
                if count > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.mood(mood)).frame(width: 6, height: 6)
                        Text("\(count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.secondary)
                    }
                    .help(mood.label)
                }
            }
        }
    }
}

private struct LimitsGrid: View {
    let providers: [ProviderLimits]
    let settings: IslandSettings
    let now: Date

    var body: some View {
        if providers.isEmpty {
            Text("No usage limits cached by T3 yet")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        } else {
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: providers.count, by: 2)), id: \.self) { start in
                    HStack(alignment: .top, spacing: 8) {
                        LimitCard(provider: providers[start], settings: settings, now: now)
                        if start + 1 < providers.count {
                            LimitCard(provider: providers[start + 1], settings: settings, now: now)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
        }
    }
}

private struct LimitCard: View {
    let provider: ProviderLimits
    let settings: IslandSettings
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(Theme.accent(provider)).frame(width: 6, height: 6)
                Text(provider.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 4)
                if let checked = provider.checkedAt {
                    let ago = Format.ago(checked, now: now)
                    Text(ago == "now" ? "just now" : "\(ago) ago")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                        .help("When T3 last checked these limits")
                }
            }
            if let note = provider.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.needsYou)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(provider.windows) { window in
                LimitBar(window: window, settings: settings, now: now)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}

private struct LimitBar: View {
    let window: LimitWindow
    let settings: IslandSettings
    let now: Date

    var body: some View {
        let left = window.remaining(at: now)
        let shown = settings.shown(left)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(shown.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
                    .help("\(Int(shown.rounded()))% of this quota \(settings.quotaWord)")
                if let resetsAt = window.resetsAt, resetsAt > now {
                    Text(Format.duration(resetsAt.timeIntervalSince(now)))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .help("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(settings.level(left))
                        .frame(width: max(4, proxy.size.width * shown / 100))
                }
            }
            .frame(height: 4)
        }
    }
}

/// A clickable section title, like T3's sidebar: title on the left, count and chevron on the right.
private struct SectionHeader: View {
    let title: String
    var count: Int?
    var detail: String?
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovered = false
    @Environment(\.usesAppKitViews) private var usesAppKitViews

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Text(title.uppercased()).tracking(0.6)
                if let detail { Text("· \(detail)").fontWeight(.regular) }
                Spacer(minLength: 8)
                if let count { Text("\(count)") }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovered ? Theme.secondary : Theme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { if usesAppKitViews { HoverTracker { hovered = $0 } } }
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.usesAppKitViews) private var usesAppKitViews

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered ? Theme.primary : Theme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { if usesAppKitViews { HoverTracker { hovered = $0 } } }
    }
}

private struct ThreadRow: View {
    let thread: T3Thread
    let now: Date
    let onOpen: () -> Void
    @State private var hovered = false
    @Environment(\.usesAppKitViews) private var usesAppKitViews

    var body: some View {
        let snoozed = thread.snoozedUntil != nil && thread.mood != .working
        let wake = snoozed ? thread.snoozedUntil : nil
        Button(action: onOpen) {
            HStack(spacing: 10) {
                BlobAvatar(seed: thread.id, mood: thread.mood, size: 28, muted: snoozed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(thread.mood == .working || snoozed ? Theme.secondary : Theme.primary)
                        .lineLimit(1)
                    Text([thread.project, thread.provider].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snoozed ? "Snoozed" : thread.mood.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(snoozed ? Theme.muted : Theme.mood(thread.mood))
                    Text(wake.map { "in \(Format.duration($0.timeIntervalSince(now)))" }
                        ?? Format.ago(thread.since ?? thread.updatedAt, now: now))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovered ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { if usesAppKitViews { HoverTracker { hovered = $0 } } }
    }
}
