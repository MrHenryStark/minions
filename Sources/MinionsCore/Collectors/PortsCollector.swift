import Foundation

/// Lists TCP listeners via `lsof` and enriches each with process metadata.
public struct PortsCollector: Sendable {
    public init() {}

    /// Ports the app should never show: system daemons nobody debugs.
    public static let ignoredProcesses: Set<String> = ["rapportd", "ControlCe", "FinderSyn", "sharingd", "identitys", "cloud-dri", "AirPlayXP", "launchd", "cupsd", "Google", "Notion", "Slack", "Spotify", "Dropbox"]

    public func collect(includeSystem: Bool = false) throws -> [ListeningPort] {
        let r = try Shell.run("lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcn"], timeout: 8)
        var ports = Self.parseFieldOutput(r.stdout)
        if !includeSystem {
            ports = ports.filter { !Self.ignoredProcesses.contains($0.processName) && $0.kind != .system }
        }
        let pids = Array(Set(ports.map(\.pid)))
        let cwds = cwdByPid(pids)
        let procs = processInfo(pids)
        return ports.map { p in
            var p = p
            p.cwd = cwds[p.pid]
            p.command = procs[p.pid]?.command
            p.startedAt = procs[p.pid]?.started
            return p
        }
    }

    // MARK: parsing

    /// Parses `lsof -F pcn` output: one field per line, `p<pid>` starts a
    /// process block, `c<cmd>` its name, `n<addr>` each socket name.
    public static func parseFieldOutput(_ text: String) -> [ListeningPort] {
        var out: [ListeningPort] = []
        var seen = Set<String>()
        var pid = 0, cmd = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int(value) ?? 0
            case "c": cmd = value
            case "n":
                // "*:5432", "127.0.0.1:8092", "[::1]:3000"
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                var addr = String(value[..<colon])
                addr = addr.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let key = "\(pid):\(port)"
                if seen.insert(key).inserted {
                    out.append(ListeningPort(port: port, address: addr, pid: pid, processName: cmd))
                }
            default: break
            }
        }
        return out.sorted { $0.port < $1.port }
    }

    /// Parses the classic table form (`lsof -iTCP -sTCP:LISTEN -P -n`), kept for fixtures.
    public static func parseTableOutput(_ text: String) -> [ListeningPort] {
        var out: [ListeningPort] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9, let pid = Int(cols[1]) else { continue }
            let name = cols[8]
            guard let colon = name.lastIndex(of: ":"), let port = Int(name[name.index(after: colon)...]) else { continue }
            let addr = String(name[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if seen.insert("\(pid):\(port)").inserted {
                out.append(ListeningPort(port: port, address: addr, pid: pid, processName: String(cols[0])))
            }
        }
        return out.sorted { $0.port < $1.port }
    }

    // MARK: enrichment

    func cwdByPid(_ pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let r = try? Shell.run("lsof", ["-a", "-d", "cwd", "-p", list, "-F", "pn"], timeout: 8) else { return [:] }
        var out: [Int: String] = [:]
        var pid = 0
        for line in r.stdout.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { out[pid] = String(line.dropFirst()) }
        }
        return out
    }

    struct Proc { let command: String; let started: Date? }

    func processInfo(_ pids: [Int]) -> [Int: Proc] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let r = try? Shell.run("ps", ["-o", "pid=,lstart=,command=", "-p", list], timeout: 5) else { return [:] }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var out: [Int: Proc] = [:]
        for line in r.stdout.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            let parts = s.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 6, let pid = Int(parts[0]) else { continue }
            // lstart is 5 tokens: "Sat Sep 19 12:27:45 2026"
            let lstart = parts[1...4].joined(separator: " ")
            // Note: parts[5] begins with the year then the command.
            let rest = parts[5].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let year = rest.first.map(String.init) ?? ""
            let command = rest.count > 1 ? String(rest[1]) : ""
            let started = df.date(from: "\(lstart) \(year)")
            out[pid] = Proc(command: command, started: started)
        }
        return out
    }

    /// Sends SIGTERM (then SIGKILL after a grace period) to the process owning a port.
    public func kill(pid: Int, force: Bool = false) throws {
        try Shell.run("kill", [force ? "-9" : "-15", String(pid)], timeout: 3)
    }
}
