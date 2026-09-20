import Foundation

/// Owns every usage record seen, prices them, deduplicates by ref, and
/// persists cursors so restarts do not rescan hundreds of MB of transcripts.
public final class UsageStore: @unchecked Sendable {
    public struct State: Codable {
        var claude: [String: ClaudeCodeReader.Cursor] = [:]
        var codex: [String: CodexReader.Cursor] = [:]
        var hermes: [String: TimeInterval] = [:]
        var pi: [String: ClaudeCodeReader.Cursor] = [:]
        var records: [UsageRecord] = []
        var version = 1
    }

    public let path: String
    public let catalog: PricingCatalog
    private var state = State()
    private var index: [String: Int] = [:]
    private let lock = NSLock()
    public let claude = ClaudeCodeReader()
    public let codex = CodexReader()
    public let hermes = HermesReader()
    public let pi = PiReader()
    public private(set) var lastScanDuration: TimeInterval = 0
    public private(set) var lastError: String?

    /// Records older than this are dropped from the persisted state.
    public var retention: TimeInterval = 90 * 86400

    public init(path: String? = nil, catalog: PricingCatalog? = nil) {
        self.path = path ?? NSHomeDirectory() + "/Library/Application Support/Minions/usage.json"
        self.catalog = catalog ?? PricingCatalog.load()
        load()
    }

    // MARK: persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: path), let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        state = s
        for (i, r) in state.records.enumerated() { index[r.dedupKey] = i }
    }

    public func save() {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-retention)
        if state.records.contains(where: { $0.ts < cutoff }) {
            state.records.removeAll { $0.ts < cutoff }
            index = [:]
            for (i, r) in state.records.enumerated() { index[r.dedupKey] = i }
        }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { lastError = "save failed: \(error.localizedDescription)" }
    }

    // MARK: collection

    /// Scans every source for new usage. Safe to call repeatedly; cheap when nothing changed.
    @discardableResult
    public func refresh() -> Int {
        let t0 = Date()
        var fresh: [UsageRecord] = []
        for file in claude.transcripts() {
            lock.lock(); var c = state.claude[file] ?? .init(); lock.unlock()
            let recs = claude.read(file: file, cursor: &c)
            lock.lock(); state.claude[file] = c; lock.unlock()
            fresh += recs
        }
        let titles = codex.titles()
        for file in codex.rollouts() {
            lock.lock(); var c = state.codex[file] ?? .init(); lock.unlock()
            if let r = codex.read(file: file, cursor: &c, titles: titles) { fresh.append(r) }
            lock.lock(); state.codex[file] = c; lock.unlock()
        }
        for h in hermes.homes() {
            lock.lock(); let since = state.hermes[h.name] ?? 0; lock.unlock()
            let (recs, high) = hermes.read(home: h, since: since)
            fresh += recs
            lock.lock(); state.hermes[h.name] = high; lock.unlock()
        }
        for file in pi.transcripts() {
            lock.lock(); var c = state.pi[file] ?? .init(); lock.unlock()
            fresh += pi.read(file: file, cursor: &c)
            lock.lock(); state.pi[file] = c; lock.unlock()
        }
        let added = upsert(fresh)
        lastScanDuration = Date().timeIntervalSince(t0)
        return added
    }

    private func upsert(_ recs: [UsageRecord]) -> Int {
        lock.lock(); defer { lock.unlock() }
        var added = 0
        for raw in recs {
            let r = catalog.price(raw)
            if let i = index[r.dedupKey] { state.records[i] = r }
            else { index[r.dedupKey] = state.records.count; state.records.append(r); added += 1 }
        }
        return added
    }

    // MARK: queries

    public var records: [UsageRecord] { lock.lock(); defer { lock.unlock() }; return state.records }

    public func records(since: Date, until: Date? = nil) -> [UsageRecord] {
        records.filter { r in r.ts >= since && (until == nil || r.ts < until!) }
    }

    public static func startOfToday() -> Date { Calendar.current.startOfDay(for: Date()) }
    public static func startOfWeek() -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? startOfToday()
    }
    public static func startOfMonth() -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? startOfToday()
    }

    public func summary(since: Date, groupBy key: (UsageRecord) -> String) -> [UsageSummary] {
        var out: [String: UsageSummary] = [:]
        for r in records(since: since) {
            let k = key(r)
            out[k, default: UsageSummary(key: k)].add(r)
        }
        return out.values.sorted { $0.costBilled > $1.costBilled }
    }

    public func total(since: Date) -> UsageSummary {
        var s = UsageSummary(key: "total")
        for r in records(since: since) { s.add(r) }
        return s
    }

    /// Cost per calendar day for the last `days` days, oldest first.
    public func daily(days: Int, agent: String? = nil) -> [(day: Date, cost: Double, tokens: Int)] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: Self.startOfToday())!
        var buckets: [Date: (Double, Int)] = [:]
        for r in records(since: start) where agent == nil || r.agent == agent {
            let d = cal.startOfDay(for: r.ts)
            let cur = buckets[d] ?? (0, 0)
            buckets[d] = (cur.0 + (r.costBilled ?? 0), cur.1 + r.total)
        }
        return (0..<days).map { i in
            let d = cal.date(byAdding: .day, value: i, to: start)!
            let b = buckets[d] ?? (0, 0)
            return (d, b.0, b.1)
        }
    }
}
