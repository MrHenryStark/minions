import Foundation

/// Reads Claude Code transcripts at `~/.claude/projects/<slug>/<id>.jsonl`.
///
/// Transcripts repeat the same `usage` block on several lines for one API
/// response, so records are deduplicated by `requestId`. Files only grow, so a
/// byte offset per file is remembered and only new bytes are read.
public struct ClaudeCodeReader: Sendable {
    public static let agent = "claude-code"
    public let home: String

    public init(home: String? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { NSString(string: $0).expandingTildeInPath }
            ?? NSHomeDirectory() + "/.claude"
    }

    public var projectsDir: String { home + "/projects" }

    public func transcripts() -> [String] {
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        var out: [String] = []
        for slug in slugs {
            let dir = projectsDir + "/" + slug
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            out += files.filter { $0.hasSuffix(".jsonl") }.map { dir + "/" + $0 }
        }
        return out
    }

    public struct Cursor: Codable, Sendable {
        public var offset: Int = 0
        public var inode: UInt64 = 0
        public var seen: [String] = []   // bounded tail of request ids
    }

    /// Reads new records from one file, updating the cursor in place.
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

        // Only complete lines are consumed; a partial trailing line waits for the next pass.
        var end = data.count
        if data.last != 0x0A { end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0 }
        guard end > 0 else { return [] }
        let chunk = data.prefix(end)
        cursor.offset += end

        let project = URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
        var seen = Set(cursor.seen)
        var out: [UsageRecord] = []
        var start = chunk.startIndex
        for i in chunk.indices where chunk[i] == 0x0A {
            let line = chunk[start..<i]
            start = i + 1
            // Cheap pre-filter before JSON parsing: the bulk of lines carry no usage.
            guard line.count > 40, Self.contains(line, "\"usage\"") else { continue }
            if let rec = Self.parse(line: line, project: project, seen: &seen) { out.append(rec) }
        }
        cursor.seen = Array(seen.sorted().suffix(500))
        return out
    }

    static func contains(_ data: Data.SubSequence, _ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static let isoPlain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    public static func parse(line: Data.SubSequence, project: String, seen: inout Set<String>) -> UsageRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>" else { return nil }
        guard let ref = (obj["requestId"] as? String) ?? (message["id"] as? String) else { return nil }
        if !seen.insert(ref).inserted { return nil }
        let sid = obj["sessionId"] as? String ?? "unknown"
        let tsStr = obj["timestamp"] as? String ?? ""
        let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr) ?? Date()
        func int(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        return UsageRecord(
            ts: ts, agent: agent, instance: project, sessionId: sid, model: model, provider: "anthropic",
            task: (obj["isSidechain"] as? Bool) == true ? "subagent" : nil,
            apiCalls: 1, input: int("input_tokens"), output: int("output_tokens"),
            cacheRead: int("cache_read_input_tokens"), cacheWrite: int("cache_creation_input_tokens"),
            cwd: obj["cwd"] as? String, ref: "\(sid):\(ref)"
        )
    }

    // MARK: sessions

    /// Session metadata from the head of each transcript. Cheap: reads at most 20 lines.
    public func sessions(limit: Int = 100) -> [DevSession] {
        let fm = FileManager.default
        let files = transcripts().compactMap { f -> (String, Date)? in
            guard let m = (try? fm.attributesOfItem(atPath: f))?[.modificationDate] as? Date else { return nil }
            return (f, m)
        }.sorted { $0.1 > $1.1 }.prefix(limit)
        var out: [DevSession] = []
        for (file, mtime) in files {
            guard let head = Self.firstJSON(file) else { continue }
            let tsStr = head["timestamp"] as? String ?? ""
            var s = DevSession(agent: Self.agent,
                               sessionId: head["sessionId"] as? String ?? URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent,
                               title: head["slug"] as? String,
                               instance: URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent,
                               cwd: head["cwd"] as? String, gitBranch: head["gitBranch"] as? String,
                               startedAt: Self.iso.date(from: tsStr) ?? Self.isoPlain.date(from: tsStr),
                               lastActivity: mtime, isLive: false)
            s.model = head["model"] as? String
            out.append(s)
        }
        return out
    }

    static func firstJSON(_ file: String) -> [String: Any]? {
        guard let fh = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 64 * 1024) else { return nil }
        var start = data.startIndex
        var n = 0
        for i in data.indices where data[i] == 0x0A {
            defer { start = i + 1; n += 1 }
            if n >= 20 { break }
            if let obj = try? JSONSerialization.jsonObject(with: data[start..<i]) as? [String: Any], obj["sessionId"] != nil { return obj }
        }
        return nil
    }
}
