import Foundation

/// Reads `pi` (the generic multi-provider coding agent) session transcripts at
/// `~/.pi/agent/sessions/<mangled-cwd>/<timestamp>_<uuid>.jsonl`.
///
/// Unlike Claude Code or Codex, a pi transcript is not tied to one provider:
/// each assistant `message` line carries its own `provider`, `model` and
/// `usage` (including a `cost.total` pi has already computed), because a
/// session can switch models mid-conversation. This is what makes pi the
/// natural place DeepSeek, local Ollama models, or anything else pi supports
/// shows up if you talk to them directly rather than through another agent.
public struct PiReader: Sendable {
    public static let agent = "pi"
    public let sessionsDir: String

    public init(sessionsDir: String? = nil) {
        self.sessionsDir = sessionsDir
            ?? ProcessInfo.processInfo.environment["PI_SESSION_DIR"].map { NSString(string: $0).expandingTildeInPath }
            ?? NSHomeDirectory() + "/.pi/agent/sessions"
    }

    public typealias Cursor = ClaudeCodeReader.Cursor

    public func transcripts() -> [String] {
        guard let e = FileManager.default.enumerator(atPath: sessionsDir) else { return [] }
        var out: [String] = []
        while let p = e.nextObject() as? String {
            if p.hasSuffix(".jsonl") { out.append(sessionsDir + "/" + p) }
        }
        return out
    }

    /// Reads new records from one transcript, updating the cursor in place.
    /// Same incremental byte-offset scheme as `ClaudeCodeReader`: files only
    /// grow, and only complete lines are consumed.
    public func read(file: String, cursor: inout Cursor) -> [UsageRecord] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file) else { return [] }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if cursor.inode != 0 && cursor.inode != inode { cursor = Cursor() }
        if cursor.offset > size { cursor = Cursor() }
        cursor.inode = inode
        guard cursor.offset < size, let fh = FileHandle(forReadingAtPath: file) else { return [] }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(cursor.offset))
        guard let data = try? fh.readToEnd() else { return [] }

        var end = data.count
        if data.last != 0x0A { end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0 }
        guard end > 0 else { return [] }
        let chunk = data.prefix(end)
        cursor.offset += end

        let sessionId = Self.sessionId(file)
        let cwd = Self.cwd(file)
        var seen = Set(cursor.seen)
        var out: [UsageRecord] = []
        var start = chunk.startIndex
        for i in chunk.indices where chunk[i] == 0x0A {
            let line = chunk[start..<i]
            start = i + 1
            guard line.count > 40, line.range(of: Data("\"usage\"".utf8)) != nil else { continue }
            if let rec = Self.parse(line: line, sessionId: sessionId, cwd: cwd, seen: &seen) { out.append(rec) }
        }
        cursor.seen = Array(seen.sorted().suffix(500))
        return out
    }

    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    public static func parse(line: Data.SubSequence, sessionId: String, cwd: String?, seen: inout Set<String>) -> UsageRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "message",
              let message = obj["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let usage = message["usage"] as? [String: Any] else { return nil }
        guard let id = obj["id"] as? String else { return nil }
        let ref = "\(sessionId):\(id)"
        if !seen.insert(ref).inserted { return nil }
        let model = (message["model"] as? String) ?? (message["responseModel"] as? String) ?? "unknown"
        let provider = (message["provider"] as? String) ?? "unknown"
        let tsStr = obj["timestamp"] as? String ?? ""
        let ts = iso.date(from: tsStr) ?? Date()
        func int(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        let cost = usage["cost"] as? [String: Any]
        let total = (cost?["total"] as? NSNumber)?.doubleValue
        return UsageRecord(
            ts: ts, agent: agent, instance: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, sessionId: sessionId,
            model: model, provider: provider,
            apiCalls: 1, input: int("input"), output: int("output"), cacheRead: int("cacheRead"), cacheWrite: int("cacheWrite"), reasoning: int("reasoning"),
            costBilled: (total ?? 0) > 0 ? total : nil, cwd: cwd, ref: ref
        )
    }

    /// `2026-07-16T14-58-46-468Z_019f6b6f-....jsonl` -> the uuid after the underscore.
    static func sessionId(_ file: String) -> String {
        let stem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        if let u = stem.split(separator: "_").last { return String(u) }
        return stem
    }

    /// The project directory, read from the transcript's own leading `session`
    /// record rather than decoded from the mangled directory name.
    static func cwd(_ file: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 4096),
              let nl = data.firstIndex(of: 0x0A),
              let obj = try? JSONSerialization.jsonObject(with: data[data.startIndex..<nl]) as? [String: Any] else { return nil }
        return obj["cwd"] as? String
    }

    /// The most recently used model, read from the tail of the file so this
    /// stays cheap even on a multi-megabyte transcript.
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

    public func sessions(limit: Int = 100) -> [DevSession] {
        let fm = FileManager.default
        let files = transcripts().compactMap { f -> (String, Date, Date?)? in
            guard let a = try? fm.attributesOfItem(atPath: f), let m = a[.modificationDate] as? Date else { return nil }
            return (f, m, a[.creationDate] as? Date)
        }.sorted { $0.1 > $1.1 }.prefix(limit)
        return files.map { file, mtime, ctime in
            let cwd = Self.cwd(file)
            return DevSession(agent: Self.agent, sessionId: Self.sessionId(file), instance: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                              model: Self.lastModel(file), cwd: cwd, startedAt: ctime, lastActivity: mtime, isLive: false)
        }
    }
}
