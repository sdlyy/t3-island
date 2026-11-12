import Foundation
import SQLite3

// MARK: - Models

/// Ordered by how much the thread needs you: working threads need nothing until they finish.
enum ThreadMood: Int, Comparable {
    case needsYou, failed, replied, idle, working

    static func < (a: ThreadMood, b: ThreadMood) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .replied: "Replied"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }
}

struct T3Thread: Identifiable, Equatable {
    let id: String
    let title: String
    let project: String
    let provider: String
    let mood: ThreadMood
    /// When the current mood started: run start while working, run end otherwise.
    let since: Date?
    let updatedAt: Date
    /// Set while the thread is snoozed in T3; it doesn't need you until then.
    var snoozedUntil: Date?
}

struct LimitWindow: Identifiable, Equatable {
    let id: String
    /// T3's window kind: "session" (5 h), "weekly" or "monthly".
    let kind: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?

    /// Quota left, 0–100. T3 only rewrites the cache when it probes, so a window past its reset is full again.
    func remaining(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 100 }
        return 100 - min(max(usedPercent, 0), 100)
    }
}

struct ProviderLimits: Identifiable, Equatable {
    let id: String
    let name: String
    let accentHex: String?
    let checkedAt: Date?
    let windows: [LimitWindow]
    /// Why the latest check failed, when T3 could not refresh these limits.
    let note: String?

    /// The window with the least quota left.
    /// The window with the least quota left, among windows of `kind` when the provider has any.
    func tightest(at now: Date, kind: String? = nil) -> LimitWindow? {
        let ofKind = windows.filter { $0.kind == kind }
        return (ofKind.isEmpty ? windows : ofKind).min { $0.remaining(at: now) < $1.remaining(at: now) }
    }
}

struct Snapshot {
    var threads: [T3Thread] = []
    var providers: [ProviderLimits] = []
    var problem: String?
}

// MARK: - Reader

/// Reads T3 Code's own state read-only. Confined to the Store's serial queue, hence unchecked.
final class T3Reader: @unchecked Sendable {
    let home: URL
    let environmentId: String?
    private var db: OpaquePointer?
    private var providerCache: (stamp: [String: Date], value: [ProviderLimits]) = ([:], [])
    private let iso = ISO8601DateFormatter()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(home: URL = T3Reader.defaultHome()) {
        self.home = home
        let envFile = home.appendingPathComponent("userdata/environment-id")
        environmentId = (try? String(contentsOf: envFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit { sqlite3_close(db) }

    static func defaultHome() -> URL {
        if let custom = ProcessInfo.processInfo.environment["T3CODE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3")
    }

    func snapshot() -> Snapshot {
        var snap = Snapshot()
        snap.providers = readProviders()
        let names = Dictionary(snap.providers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        do {
            snap.threads = try readThreads(providerNames: names)
        } catch {
            snap.problem = "\(error)"
            sqlite3_close(db)
            db = nil
        }
        return snap
    }

    // MARK: Limits: ~/.t3/caches/<provider>.json → usageLimits

    private struct ProviderFile: Decodable {
        struct Limits: Decodable {
            let checkedAt: String?
            let windows: [Window]?
            let unavailable: Unavailable?
        }
        struct Unavailable: Decodable {
            let reason: String?
            let message: String?
        }
        struct Window: Decodable {
            let id: String
            let kind: String?
            let label: String?
            let usedPercent: Double?
            let resetsAt: String?
        }
        let displayName: String?
        let enabled: Bool?
        let accentColor: String?
        let usageLimits: Limits?
    }

    private func readProviders() -> [ProviderLimits] {
        let dir = home.appendingPathComponent("caches")
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).filter { $0.pathExtension == "json" }

        var stamp: [String: Date] = [:]
        for file in files {
            stamp[file.lastPathComponent] =
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        if stamp == providerCache.stamp { return providerCache.value }

        let decoder = JSONDecoder()
        var result: [ProviderLimits] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let parsed = try? decoder.decode(ProviderFile.self, from: data),
                  parsed.enabled != false,
                  let limits = parsed.usageLimits
            else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            var checkedAt = date(limits.checkedAt)
            var note: String?
            var windows: [LimitWindow] = (limits.windows ?? []).compactMap { w in
                guard let used = w.usedPercent else { return nil }
                return LimitWindow(id: w.id, kind: w.kind ?? "", label: w.label ?? w.id, usedPercent: used,
                                   resetsAt: date(w.resetsAt))
            }
            if windows.isEmpty {
                guard let unavailable = limits.unavailable, unavailable.reason != "unsupported" else { continue }
                // A failed check blanks T3's cache; keep the last values seen instead of dropping the card.
                let previous = providerCache.value.first { $0.id == id && !$0.windows.isEmpty }
                windows = previous?.windows ?? []
                checkedAt = previous?.checkedAt
                note = unavailable.message ?? "T3 could not check these limits."
            }
            result.append(ProviderLimits(
                id: id,
                name: parsed.displayName ?? id,
                accentHex: parsed.accentColor,
                checkedAt: checkedAt,
                windows: windows,
                note: note
            ))
        }
        // Claude first, then Codex, then the rest by name.
        let order = ["claudeAgent": 0, "codex": 1]
        result.sort { (order[$0.id] ?? 9, $0.name) < (order[$1.id] ?? 9, $1.name) }
        providerCache = (stamp, result)
        return result
    }

    // MARK: Threads: ~/.t3/userdata/statev2.sqlite

    struct DBError: Error, CustomStringConvertible {
        let description: String
    }

    /// The inbox: unsettled top-level threads, plus any thread with a live run or an open question.
    private static let threadsSQL = """
        WITH t AS (
          SELECT thread_id, project_id, title, updated_at,
                 COALESCE(provider_instance_id, default_provider) AS provider,
                 json_extract(payload_json, '$.lastVisitedAt') AS visited_at,
                 json_extract(payload_json, '$.settledAt') AS settled_at,
                 json_extract(payload_json, '$.snoozedUntil') AS snoozed_until,
                 json_extract(payload_json, '$.snoozedAt') AS snoozed_at
          FROM orchestration_v2_projection_threads
          WHERE archived_at IS NULL AND deleted_at IS NULL
            AND COALESCE(json_extract(payload_json, '$.lineage.relationshipToParent'), '') <> 'subagent'
        ),
        x AS (
          SELECT t.*, p.title AS project, r.status AS run_status, r.requested_at, r.completed_at,
                 (SELECT COUNT(*) FROM orchestration_v2_projection_runtime_requests q
                   WHERE q.thread_id = t.thread_id AND q.status = 'pending') AS pending,
                 (SELECT COUNT(*) FROM orchestration_v2_projection_runtime_requests q
                   WHERE q.thread_id = t.thread_id AND q.status = 'pending'
                     AND (q.kind <> 'user_input' OR t.snoozed_at IS NULL OR q.created_at > t.snoozed_at)) AS waking
          FROM t
          LEFT JOIN projection_projects p ON p.project_id = t.project_id
          LEFT JOIN orchestration_v2_projection_runs r ON r.thread_id = t.thread_id
            AND r.ordinal = (SELECT MAX(ordinal) FROM orchestration_v2_projection_runs r2
                             WHERE r2.thread_id = t.thread_id)
        )
        SELECT thread_id, title, COALESCE(project, ''), provider, updated_at, visited_at,
               run_status, requested_at, completed_at, pending, snoozed_until, snoozed_at, waking
        FROM x
        WHERE settled_at IS NULL
           OR pending > 0
           OR run_status IN ('queued', 'preparing', 'starting', 'running', 'waiting')
        ORDER BY updated_at DESC
        LIMIT 40
        """

    private func openIfNeeded() throws -> OpaquePointer {
        if let db { return db }
        let path = home.appendingPathComponent("userdata/statev2.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else {
            throw DBError(description: "T3 Code state not found at \(path)")
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(handle)
            throw DBError(description: "Cannot open T3 state: \(message)")
        }
        sqlite3_busy_timeout(handle, 250)
        // T3 writes constantly while agents run, which drops SQLite's page cache; mmap keeps re-reads cheap.
        sqlite3_exec(handle, "PRAGMA mmap_size = 268435456", nil, nil, nil)
        db = handle
        return handle
    }

    private func readThreads(providerNames: [String: String]) throws -> [T3Thread] {
        let db = try openIfNeeded()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.threadsSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError(description: "T3 schema changed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        var threads: [T3Thread] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DBError(description: "T3 query failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            func text(_ i: Int32) -> String? {
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            let provider = text(3) ?? ""
            let visitedAt = date(text(5))
            let runStatus = text(6)
            let requestedAt = date(text(7))
            let completedAt = date(text(8))
            let pending = sqlite3_column_int(stmt, 9)
            let snoozedUntil = date(text(10))
            let snoozedAt = date(text(11))

            let mood: ThreadMood
            switch runStatus {
            case _ where pending > 0: mood = .needsYou
            case "waiting": mood = .needsYou
            case "queued", "preparing", "starting", "running": mood = .working
            case "failed": mood = .failed
            case "completed" where (completedAt ?? .distantPast) > (visitedAt ?? .distantPast): mood = .replied
            default: mood = .idle
            }

            threads.append(T3Thread(
                id: text(0) ?? UUID().uuidString,
                title: text(1) ?? "Untitled",
                project: text(2) ?? "",
                provider: providerNames[provider] ?? provider,
                mood: mood,
                since: mood == .working || mood == .needsYou ? requestedAt : completedAt,
                updatedAt: date(text(4)) ?? .distantPast,
                snoozedUntil: Self.isSnoozed(until: snoozedUntil, at: snoozedAt, wakingRequests: sqlite3_column_int(stmt, 12),
                                             runStatus: runStatus, completedAt: completedAt) ? snoozedUntil : nil
            ))
        }
        // Stable sort: attention first, newest first within a mood.
        return threads.enumerated()
            .sorted { ($0.element.mood, $0.offset) < ($1.element.mood, $1.offset) }
            .map(\.element)
    }

    /// T3's own rule (isSnoozed in its server): a snooze holds until its time, unless a new question
    /// or a new failure arrived after the thread was snoozed.
    private static func isSnoozed(until: Date?, at: Date?, wakingRequests: Int32, runStatus: String?, completedAt: Date?) -> Bool {
        guard let until, until > Date(), wakingRequests == 0 else { return false }
        guard runStatus == "failed" else { return true }
        guard let at else { return false }
        return completedAt.map { $0 <= at } ?? true
    }

    private func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoFrac.date(from: string) ?? iso.date(from: string)
    }

    func threadURL(_ threadId: String) -> URL? {
        guard let environmentId else { return nil }
        return URL(string: "t3code://threads/\(environmentId)/\(threadId)")
    }
}
