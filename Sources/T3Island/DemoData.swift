import Foundation

/// Made-up threads and limits for `--demo`: screenshots without real data, and a live check of the
/// update animations. Each refresh moves one thread to its next state.
struct DemoData {
    private static let threads = [
        ("Refactor billing webhooks", "payments-api"), ("Fix flaky checkout test", "web"),
        ("Draft Q3 roadmap notes", "planning"), ("Migrate cron jobs to queues", "infra"),
        ("Review onboarding copy", "web"), ("Upgrade Postgres to 17", "infra"),
        ("Investigate worker memory leak", "worker"), ("Tidy up feature flags", "web"),
    ]
    private var moods: [ThreadMood] = [.needsYou, .replied, .idle, .working, .idle, .waiting, .failed, .idle]
    private var step = 0

    /// Made-up lines: what each thread last said, and the steps working threads go through, one per refresh.
    private static let said = [
        "Should retries run on every webhook, or only after a 5xx?",
        "Fixed the race: CartTest now waits for the debounce before asserting.",
        "The draft is in roadmap-q3.md. Want me to tighten the intro?",
        "Moved all six jobs to the queue; the old cron entries are gone.",
        "Rewrote the welcome screen copy. Two options for the headline.",
        "Opened #42 for the upgrade. Waiting for its checks.",
        "error: no such module 'PostgresNIO'",
        "Removed four stale flags; two are still read by the billing service.",
    ]
    private static let steps = [
        "$ swift test --filter CheckoutTests", "Edited JobQueue.swift", "Thinking…",
        "Searching “pg_upgrade link mode”", "Read MIGRATION.md", "Now updating the worker to read from the queue",
    ]

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
                     updatedAt: now.addingTimeInterval(-Double(i * 60)),
                     snoozedUntil: i == 7 ? now.addingTimeInterval(2 * 3600 + 600) : nil,
                     waitingOn: moods[i] == .waiting ? "PR #42" : nil,
                     line: moods[i] == .working ? Self.steps[(step + i) % Self.steps.count] : Self.said[i])
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
        case .working, .waiting: .replied
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
