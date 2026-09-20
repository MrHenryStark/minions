import Foundation

/// Reads Codex rollouts at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
/// `total_token_usage` snapshots are cumulative per session, so only the delta
/// since the previous pass is emitted.
public struct CodexReader: Sendable {
    public static let agent = "codex"
    public let home: String

    public init(home: String? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { NSString(string: $0).expandingTildeInPath } ?? NSHomeDirectory() + "/.codex"
    }

    public struct Cursor: Codable, Sendable {
        public var mtime: TimeInterval = 0
        public var totals: [String: Int] = [:]
    }

    public func rollouts() -> [String] {
        let root = home + "/sessions"
        guard let e = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        while let p = e.nextObject() as? String {
            if p.hasSuffix(".jsonl"), (p as NSString).lastPathComponent.hasPrefix("rollout-") { out.append(root + "/" + p) }
        }
        return out
    }

    public func read(file: String, cursor: inout Cursor, titles: [String: String]) -> UsageRecord? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        if cursor.mtime >= mtime && !cursor.totals.isEmpty { return nil }
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        let (latest, model) = Self.scan(data)
        cursor.mtime = mtime
        guard let latest else { return nil }
        let previous = cursor.totals
        cursor.totals = latest
        var delta: [String: Int] = [:]
        for (k, v) in latest { delta[k] = max(0, v - (previous[k] ?? 0)) }
        guard delta.values.contains(where: { $0 > 0 }) else { return nil }
        let sid = Self.sessionId(file)
        let cached = delta["cached_input_tokens"] ?? 0
        return UsageRecord(
            ts: Date(timeIntervalSince1970: mtime), agent: Self.agent, instance: titles[sid], sessionId: sid,
            model: model ?? "unknown", provider: "openai-codex", apiCalls: 1,
            input: max(0, (delta["input_tokens"] ?? 0) - cached), output: delta["output_tokens"] ?? 0,
            cacheRead: cached, reasoning: delta["reasoning_output_tokens"] ?? 0,
            ref: "\(sid):\(Int(mtime))"
        )
    }

    public static func scan(_ data: Data) -> ([String: Int]?, String?) {
        var latest: [String: Int]?
        var model: String?
        let usageNeedle = Data("\"total_token_usage\"".utf8), modelNeedle = Data("\"model\"".utf8)
        func consume(_ line: Data.SubSequence) {
            guard line.range(of: usageNeedle) != nil || line.range(of: modelNeedle) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) else { return }
            if let u = find(obj, "total_token_usage") as? [String: Any] {
                latest = u.compactMapValues { ($0 as? NSNumber)?.intValue }
            }
            if let m = find(obj, "model") as? String, !m.isEmpty { model = m }
        }
        var start = data.startIndex
        for i in data.indices where data[i] == 0x0A {
            consume(data[start..<i]); start = i + 1
        }
        if start < data.endIndex { consume(data[start..<data.endIndex]) }
        return (latest, model)
    }

    static func find(_ obj: Any, _ key: String, depth: Int = 0) -> Any? {
        guard depth < 7 else { return nil }
        if let d = obj as? [String: Any] {
            if let v = d[key] { return v }
            for v in d.values { if let f = find(v, key, depth: depth + 1) { return f } }
        } else if let a = obj as? [Any] {
            for v in a { if let f = find(v, key, depth: depth + 1) { return f } }
        }
        return nil
    }

    static func sessionId(_ file: String) -> String {
        let stem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : stem
    }

    public func titles() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: home + "/session_index.jsonl") else { return [:] }
        var out: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = o["id"] as? String, let t = o["thread_name"] as? String { out[id] = t }
        }
        return out
    }

    public func sessions(limit: Int = 50) -> [DevSession] {
        let t = titles()
        let fm = FileManager.default
        return rollouts().compactMap { f -> DevSession? in
            guard let a = try? fm.attributesOfItem(atPath: f), let m = a[.modificationDate] as? Date else { return nil }
            let sid = Self.sessionId(f)
            return DevSession(agent: Self.agent, sessionId: sid, title: t[sid], model: Self.lastModel(f), startedAt: a[.creationDate] as? Date, lastActivity: m, isLive: false)
        }.sorted { $0.lastActivity > $1.lastActivity }.prefix(limit).map { $0 }
    }

    /// The most recently used model, read from the tail of the rollout so this
    /// stays cheap even on a multi-megabyte transcript (unlike `_scan`, which
    /// reads the whole file and is only meant for the incremental collector).
    static func lastModel(_ file: String, tail: Int = 64 * 1024) -> String? {
        guard let fh = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        var last: String?
        let re = try! NSRegularExpression(pattern: "\"model\"\\s*:\\s*\"([^\"]+)\"")
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            last = ns.substring(with: m.range(at: 1))
        }
        return last
    }
}
