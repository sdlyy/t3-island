import Foundation

/// Made-up threads and limits for `--demo`: screenshots without real data, and a live check of the
/// update animations. Each refresh moves one thread to its next state.
struct DemoData {
    private static let threads = [
        ("Refactor billing webhooks", "payments-api"), ("Fix flaky checkout test", "web"),
        ("Draft Q3 roadmap notes", "planning"), ("Migrate cron jobs to queues", "infra"),
        ("Review onboarding copy", "web"), ("Upgrade Postgres to 17", "infra"),
        ("Investigate worker memory leak", "worker"),
    ]
    private var moods: [ThreadMood] = [.needsYou, .replied, .idle, .working, .idle, .working, .failed]
    private var step = 0

    mutating func next() -> Snapshot {
        if step > 0 {
            let i = (step * 3) % moods.count
            moods[i] = Self.after(moods[i])
        }
        step += 1

        let now = Date()
        let threads = Self.threads.enumerated().map { i, item in
            T3Thread(id: "demo-\(i)", title: item.0, project: item.1, provider: i % 3 == 2 ? "Codex" : "Claude",
                     mood: moods[i], since: now.addingTimeInterval(-Double(90 + i * 1500)),
                     updatedAt: now.addingTimeInterval(-Double(i * 60)), snoozedUntil: nil)
        }
        return Snapshot(
            threads: threads.enumerated().sorted { ($0.element.mood, $0.offset) < ($1.element.mood, $1.offset) }.map(\.element),
            providers: [
                Self.provider("claudeAgent", "Claude", nil, now, [("session", "Session", 16, 3.3), ("weekly", "Weekly", 38, 70)]),
                Self.provider("codex", "Codex", "#2563eb", now, [("session", "Session", 0, 4.6), ("weekly", "Weekly", 9, 140)]),
            ]
        )
    }

    private static func after(_ mood: ThreadMood) -> ThreadMood {
        switch mood {
        case .working: .replied
        case .replied: .idle
        case .idle, .needsYou, .failed: .working
        }
    }

    private static func provider(_ id: String, _ name: String, _ accent: String?, _ now: Date,
                                 _ windows: [(String, String, Double, Double)]) -> ProviderLimits {
        ProviderLimits(id: id, name: name, accentHex: accent, checkedAt: now.addingTimeInterval(-60),
                       windows: windows.map { kind, label, used, hours in
                           LimitWindow(id: "\(id)-\(kind)", kind: kind, label: label, usedPercent: used,
                                       resetsAt: now.addingTimeInterval(hours * 3600))
                       },
                       note: nil)
    }
}
