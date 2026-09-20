import Foundation
import SQLite3

/// Reads Hermes usage from `session_model_usage` in every home's `state.db`:
/// the root `~/.hermes` plus each `~/.hermes/profiles/<name>/`. Databases are
/// opened read-only; live writers are never disturbed.
public struct HermesReader: Sendable {
    public static let agent = "hermes"
    public let home: String

    public init(home: String? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["HERMES_HOME"].map { NSString(string: $0).expandingTildeInPath } ?? NSHomeDirectory() + "/.hermes"
    }

    public struct Home: Sendable { public let name: String; public let path: String; public let isRoot: Bool
        var db: String { path + "/state.db" } }

    public func homes() -> [Home] {
        var out = [Home(name: "(root)", path: home, isRoot: true)]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: home + "/profiles") {
            for n in names.sorted() where FileManager.default.fileExists(atPath: home + "/profiles/\(n)/state.db") {
                out.append(Home(name: n, path: home + "/profiles/\(n)", isRoot: false))
            }
        }
        return out.filter { FileManager.default.fileExists(atPath: $0.db) }
    }

    /// Rows updated after `since` (minus a 5-minute overlap; rows mutate in place
    /// while a session runs and are upserted by ref downstream).
    public func read(home h: Home, since: TimeInterval) -> (records: [UsageRecord], high: TimeInterval) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(h.db, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return ([], since) }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let sql = """
        SELECT u.session_id, u.model, u.billing_provider, u.billing_mode, u.task,
               u.api_call_count, u.input_tokens, u.output_tokens, u.cache_read_tokens, u.cache_write_tokens, u.reasoning_tokens,
               u.estimated_cost_usd, u.actual_cost_usd, u.first_seen, u.last_seen, s.profile_name, s.source, s.cwd
          FROM session_model_usage u LEFT JOIN sessions s ON s.id = u.session_id
         WHERE u.last_seen > ? ORDER BY u.last_seen
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return ([], since) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, max(0, since - 300))
        var out: [UsageRecord] = []
        var high = since
        func str(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func dbl(_ i: Int32) -> Double? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let lastSeen = dbl(14) ?? 0, firstSeen = dbl(13) ?? lastSeen
            high = max(high, lastSeen)
            let reported = dbl(12) ?? dbl(11)
            let profile = str(15), source = str(16)
            let instance = (h.isRoot ? (profile ?? source ?? "(root)") : profile) ?? h.name
            let model = str(1) ?? "unknown", provider = str(2) ?? "unknown", task = str(4)
            let sid = str(0) ?? ""
            out.append(UsageRecord(
                ts: Date(timeIntervalSince1970: lastSeen), agent: Self.agent, instance: instance, sessionId: sid,
                model: model, provider: provider, billingMode: BillingMode(rawValue: str(3) ?? "") ?? .unknown, task: task,
                apiCalls: int(5), input: int(6), output: int(7), cacheRead: int(8), cacheWrite: int(9), reasoning: int(10),
                costBilled: (reported ?? 0) > 0 ? reported : nil, cwd: str(17),
                ref: "\(h.name):\(sid):\(model):\(provider):\(task ?? ""):\(String(format: "%.6f", firstSeen))"
            ))
        }
        return (out, high)
    }

    public func sessions(limit: Int = 50) -> [DevSession] {
        var out: [DevSession] = []
        for h in homes() {
            var db: OpaquePointer?
            guard sqlite3_open_v2(h.db, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 500)
            var stmt: OpaquePointer?
            let sql = "SELECT id, source, model, profile_name, title, started_at, ended_at, last_activity_at, cwd, git_branch FROM sessions ORDER BY COALESCE(last_activity_at, started_at) DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            func str(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
            func date(_ i: Int32) -> Date? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, i)) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let profile = str(3), source = str(1)
                let last = date(7) ?? date(5) ?? Date.distantPast
                var s = DevSession(agent: Self.agent, sessionId: str(0) ?? "", title: str(4),
                                   instance: (h.isRoot ? (profile ?? source ?? "(root)") : profile) ?? h.name,
                                   model: str(2), cwd: str(8), gitBranch: str(9), startedAt: date(5), lastActivity: last,
                                   isLive: date(6) == nil && Date().timeIntervalSince(last) < 600)
                s.title = s.title ?? source
                out.append(s)
            }
            sqlite3_finalize(stmt)
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }.prefix(limit).map { $0 }
    }

    /// Gateway liveness from `gateway_state.json`, cross-checked against the pid.
    public func gatewayRunning() -> Bool {
        guard let data = FileManager.default.contents(atPath: home + "/gateway_state.json"),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (o["pid"] as? NSNumber)?.int32Value else { return false }
        return o["gateway_state"] as? String == "running" && kill(pid, 0) == 0
    }
}
