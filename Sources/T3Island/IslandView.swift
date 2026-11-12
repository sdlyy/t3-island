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
        .animation(store.motion, value: store.threads)
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
        let working = settings.showWorking ? threads.filter { $0.mood.isBusy } : []
        let waiting = settings.showWaiting ? threads.filter { !$0.mood.isBusy } : []
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
            let waiting = settings.value.showWaiting ? threads.filter { !$0.mood.isBusy } : []
            let working = settings.value.showWorking ? threads.filter { $0.mood.isBusy } : []
            let snoozed = settings.value.showWaiting
                ? store.threads.filter { $0.snoozedUntil != nil && !$0.mood.isBusy } : []
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
                            // A question needs an answer in T3, so it gets no shortcuts here.
                            row(thread, now: now, actions: thread.mood == .needsYou ? .none : .organize)
                        }
                    }
                    if !working.isEmpty {
                        SectionHeader(title: "Working", count: working.count, isOpen: isOpen(.working)) {
                            toggle(.working)
                        }
                        .padding(.top, waiting.isEmpty ? 0 : 6)
                        ForEach(working.prefix(workingShown)) { thread in
                            row(thread, now: now, actions: .none)
                        }
                    }
                    if let wake = snoozed.compactMap(\.snoozedUntil).min() {
                        SectionHeader(title: "Snoozed", count: snoozed.count,
                                      detail: "back in \(Format.duration(wake.timeIntervalSince(now)))",
                                      isOpen: isOpen(.snoozed)) { toggle(.snoozed) }
                            .padding(.top, waiting.isEmpty && working.isEmpty ? 0 : 6)
                        ForEach(snoozed.prefix(snoozedShown)) { thread in
                            row(thread, now: now, actions: .wake)
                        }
                    }
                }

                HStack {
                    ZStack(alignment: .leading) {
                        if let notice = store.notice {
                            NoticeLine(notice: notice, undo: store.undo)
                                .id(notice.id)
                                .transition(.opacity.combined(with: .offset(y: 4)).combined(with: .blurred))
                        } else {
                            FooterButton(title: hidden > 0 ? "+\(hidden) more in T3 Code" : "Open T3 Code") { onOpen(nil) }
                                .transition(.opacity.combined(with: .blurred))
                        }
                    }
                    .animation(Theme.act, value: store.notice?.id)
                    Spacer()
                    FooterButton(title: "Settings", action: onSettings)
                    FooterButton(title: "Quit") { NSApp.terminate(nil) }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func row(_ thread: T3Thread, now: Date, actions: RowActions) -> some View {
        ThreadRow(thread: thread, now: now, actions: settings.value.threadActions ? actions : .none,
                  onOpen: { onOpen(thread) },
                  onSettle: { store.settle(thread) },
                  onSnooze: { store.snooze(thread, until: $0) },
                  onWake: { store.wake(thread) },
                  onHover: { store.hold(thread.id, $0) })
            .matchedGeometryEffect(id: thread.id, in: rows)
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
                // Waiting threads count with working ones: neither needs you.
                let count = threads.filter { mood == .working ? $0.mood.isBusy : $0.mood == mood }.count
                if count > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.mood(mood)).frame(width: 6, height: 6)
                        Text("\(count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.secondary)
                            .contentTransition(.numericText())
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
                if let count { Text("\(count)").contentTransition(.numericText()) }
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

/// What the last action did, with Undo, or why it failed.
private struct NoticeLine: View {
    let notice: ActionNotice
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(notice.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(notice.isError ? Theme.failed : Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 8)
            if notice.undo != nil {
                FooterButton(title: "Undo", action: undo)
            }
        }
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

/// What a row offers on hover.
private enum RowActions {
    case none
    /// Threads waiting on you: snooze or settle.
    case organize
    /// Snoozed threads: wake now.
    case wake
}

private enum Reaction {
    case settle, snooze, wake
}

private struct ThreadRow: View {
    let thread: T3Thread
    let now: Date
    var actions = RowActions.none
    let onOpen: () -> Void
    var onSettle: () -> Void = {}
    var onSnooze: (Date) -> Void = { _ in }
    var onWake: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    @State private var hovered = false
    @State private var choosingSnooze = false
    /// Set the moment an action is picked: the face reacts before the row leaves.
    @State private var reaction: Reaction?
    @Environment(\.usesAppKitViews) private var usesAppKitViews
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let snoozed = thread.snoozedUntil != nil && !thread.mood.isBusy
        let asleep = reaction == .snooze || (snoozed && reaction != .wake)
        let showActions = actions != .none && hovered && reaction == nil
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    avatar(asleep: asleep)
                    VStack(alignment: .leading, spacing: 2) {
                        // The title keeps its room; the project and model tag gives way first.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(thread.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(thread.mood.isBusy || asleep ? Theme.secondary : Theme.primary)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text([thread.project, thread.provider].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                        LiveLine(text: thread.line, attention: !thread.mood.isBusy && !asleep)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ZStack(alignment: .trailing) {
                if let reaction {
                    outcome(reaction).transition(swap)
                } else if showActions && choosingSnooze {
                    SnoozeChoices(now: now) { until in commit(.snooze) { onSnooze(until) } }
                        .fixedSize()
                        .transition(swap)
                } else if showActions {
                    HStack(spacing: 4) {
                        if actions == .organize {
                            RowButton(icon: "moon.zzz.fill", help: "Snooze") {
                                withAnimation(.easeOut(duration: 0.18)) { choosingSnooze = true }
                            }
                            RowButton(icon: "checkmark", help: "Settle") { commit(.settle, onSettle) }
                        } else {
                            RowButton(icon: "sun.max.fill", help: "Wake up now") { commit(.wake, onWake) }
                        }
                    }
                    .transition(swap)
                } else {
                    status(snoozed: snoozed)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onOpen)
                        .transition(swap)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovered ? Color.white.opacity(0.07) : .clear)
        )
        .background {
            if usesAppKitViews {
                HoverTracker { inside in
                    onHover(inside)
                    withAnimation(.easeOut(duration: 0.15)) {
                        hovered = inside
                        if !inside { choosingSnooze = false }
                    }
                }
            }
        }
        .onDisappear { onHover(false) }
        // A row that's still here a moment after reacting means the action failed and it came back.
        .task(id: reaction) {
            guard reaction != nil else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            reaction = nil
        }
        .transition(.asymmetric(insertion: .opacity, removal: exit))
    }

    private func avatar(asleep: Bool) -> some View {
        BlobAvatar(seed: thread.id, mood: reaction == .settle ? .replied : thread.mood, size: 28,
                   muted: asleep, sleeping: asleep)
            .overlay(alignment: .bottomTrailing) {
                if reaction == .settle {
                    Circle()
                        .fill(Theme.working)
                        .frame(width: 13, height: 13)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.black))
                        .offset(x: 2, y: 2)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if reaction == .snooze && !reduceMotion { FloatingZ().offset(x: 4, y: -2) }
            }
    }

    private func status(snoozed: Bool) -> some View {
        let wake = snoozed ? thread.snoozedUntil : nil
        return VStack(alignment: .trailing, spacing: 2) {
            Text(snoozed ? "Snoozed" : thread.status)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(snoozed ? Theme.muted : Theme.mood(thread.mood))
            Text(wake.map { "in \(Format.duration($0.timeIntervalSince(now)))" }
                ?? Format.ago(thread.since ?? thread.updatedAt, now: now))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
    }

    private func outcome(_ reaction: Reaction) -> some View {
        Text(reaction == .settle ? "Settled" : reaction == .snooze ? "Snoozed" : "Awake")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(reaction == .settle ? Theme.working : reaction == .snooze ? Theme.muted : Theme.needsYou)
    }

    /// The face reacts first, then the row leaves: a short beat so you see what happened.
    private func commit(_ reaction: Reaction, _ perform: @escaping () -> Void) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            self.reaction = reaction
            choosingSnooze = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.28), execute: perform)
    }

    /// Settled rows leave to the right, snoozed ones sink towards the Snoozed section. Exits are quicker than
    /// the rows closing the gap, so a leaving row is gone before its neighbours slide over it.
    private var exit: AnyTransition {
        let quick = Animation.easeOut(duration: 0.15)
        if reduceMotion { return .opacity.animation(quick) }
        switch reaction {
        case .settle: return .offset(x: 36).combined(with: .opacity).animation(quick)
        case .snooze: return .offset(y: 6).combined(with: .scale(scale: 0.97)).combined(with: .opacity).animation(quick)
        case .wake, nil: return .opacity
        }
    }

    /// Blur hides the crossfade between the status and the buttons.
    private var swap: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)).combined(with: .blurred)
    }
}

/// The latest thing a thread said or did. A new line slides up into place, so updates read as a ticker.
private struct LiveLine: View {
    let text: String?
    /// Brighter for threads waiting on you, whose line is the reply or question to read.
    let attention: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if let text {
                Text(text)
                    .font(text.hasPrefix("$ ") ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                    .foregroundStyle(attention ? Theme.secondary : Theme.muted)
                    .lineLimit(1)
                    .id(text)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: 6).combined(with: .opacity).combined(with: .blurred),
                        removal: .offset(y: -6).combined(with: .opacity).combined(with: .blurred)
                    ))
            }
        }
        // Holds the row's height while a line is loading or there is none.
        .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
        .clipped()
        .animation(.easeOut(duration: 0.22), value: text)
    }
}

private struct RowButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovered ? Theme.primary : Theme.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .help(help)
        .background(HoverTracker { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside } })
    }
}

/// Snooze lengths, sliding in one after another.
private struct SnoozeChoices: View {
    let now: Date
    let choose: (Date) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.options(now).enumerated()), id: \.offset) { index, option in
                SnoozeChip(title: option.title, help: Format.clock(option.date, now: now), delay: Double(index) * 0.03) {
                    choose(option.date)
                }
            }
        }
    }

    static func options(_ now: Date) -> [(title: String, date: Date)] {
        let calendar = Calendar.current
        let morning = DateComponents(hour: 9, minute: 0)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now).flatMap {
            calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0)
        } ?? now.addingTimeInterval(86400)
        var monday = morning
        monday.weekday = 2
        // From tomorrow, so on a Monday morning it means next Monday, not later today.
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let nextWeek = calendar.nextDate(after: startOfTomorrow, matching: monday, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(7 * 86400)
        return [
            ("1h", now.addingTimeInterval(3600)), ("3h", now.addingTimeInterval(3 * 3600)),
            ("Tomorrow", tomorrow), ("Next week", nextWeek),
        ]
    }
}

private struct SnoozeChip: View {
    let title: String
    let help: String
    let delay: Double
    let action: () -> Void
    @State private var shown = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovered ? Theme.primary : Theme.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(hovered ? 0.16 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .help(help)
        .background(HoverTracker { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside } })
        .opacity(shown ? 1 : 0)
        .offset(x: shown || reduceMotion ? 0 : 8)
        .onAppear { withAnimation(.easeOut(duration: 0.2).delay(delay)) { shown = true } }
    }
}

/// Two little z's drifting up from a face that just fell asleep.
private struct FloatingZ: View {
    @State private var up = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(0..<2) { index in
                Text("z")
                    .font(.system(size: index == 0 ? 9 : 7, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .offset(x: CGFloat(index) * 5, y: up ? -9 - CGFloat(index) * 4 : 0)
                    .opacity(up ? 0 : 1)
                    .animation(.easeOut(duration: 0.55).delay(Double(index) * 0.08), value: up)
            }
        }
        .onAppear { up = true }
    }
}

/// Buttons give a little under the pointer.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

private extension AnyTransition {
    static var blurred: AnyTransition {
        .modifier(active: BlurModifier(radius: 3), identity: BlurModifier(radius: 0))
    }
}
