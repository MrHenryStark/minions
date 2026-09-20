import Foundation

/// Reads containers through the `docker` CLI's JSON output. The CLI already
/// knows how to find the socket (Docker Desktop, Colima, OrbStack), so this is
/// more portable than speaking the Engine API over a hard-coded socket path.
public struct DockerCollector: Sendable {
    public init() {}

    public struct Snapshot: Sendable {
        public var state: DockerState
        public var containers: [DockerContainer]
    }

    public func collect(withStats: Bool = true) -> Snapshot {
        guard Shell.resolve("docker") != nil else {
            return Snapshot(state: .unavailable("docker CLI not found"), containers: [])
        }
        let r: Shell.Result
        do {
            r = try Shell.run("docker", ["ps", "-a", "--format", "{{json .}}"], timeout: 6)
        } catch {
            return Snapshot(state: .stopped, containers: [])
        }
        guard r.ok else { return Snapshot(state: .stopped, containers: []) }
        var containers = Self.parsePS(r.stdout)
        if withStats, containers.contains(where: \.isRunning),
           let s = try? Shell.run("docker", ["stats", "--no-stream", "--format", "{{json .}}"], timeout: 8), s.ok {
            let stats = Self.parseStats(s.stdout)
            containers = containers.map { c in
                var c = c
                if let st = stats[c.id] ?? stats[c.name] { c.cpuPercent = st.cpu; c.memUsage = st.mem }
                return c
            }
        }
        return Snapshot(state: .running, containers: containers)
    }

    // MARK: parsing

    struct PSRow: Decodable {
        let ID: String; let Names: String; let Image: String; let State: String; let Status: String
        let Ports: String; let Labels: String
    }

    public static func parsePS(_ text: String) -> [DockerContainer] {
        let dec = JSONDecoder()
        var out: [DockerContainer] = []
        for line in text.split(separator: "\n") {
            guard let row = try? dec.decode(PSRow.self, from: Data(line.utf8)) else { continue }
            let labels = parseLabels(row.Labels)
            out.append(DockerContainer(
                id: row.ID,
                name: row.Names.split(separator: ",").first.map(String.init) ?? row.Names,
                image: row.Image,
                state: row.State,
                status: row.Status,
                ports: parsePorts(row.Ports),
                composeProject: labels["com.docker.compose.project"],
                serviceName: labels["com.docker.compose.service"],
                composeDir: labels["com.docker.compose.project.working_dir"]
            ))
        }
        return out.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
    }

    /// Labels arrive as `k=v,k2=v2`; values may themselves contain commas
    /// (image descriptions). We only care about compose keys, so split on
    /// `,com.docker.compose.` boundaries and tolerate the rest being noisy.
    static func parseLabels(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for chunk in s.split(separator: ",") {
            guard let eq = chunk.firstIndex(of: "=") else { continue }
            let k = String(chunk[..<eq]), v = String(chunk[chunk.index(after: eq)...])
            if k.hasPrefix("com.docker.compose.") { out[k] = v }
        }
        return out
    }

    /// "0.0.0.0:6379->6379/tcp, 1110/tcp, 0.0.0.0:9000-9001->9000-9001/tcp"
    public static func parsePorts(_ s: String) -> [DockerPortMapping] {
        var out: [DockerPortMapping] = []
        for raw in s.split(separator: ",") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            let protoSplit = part.split(separator: "/", maxSplits: 1)
            let proto = protoSplit.count > 1 ? String(protoSplit[1]) : "tcp"
            let body = String(protoSplit[0])
            if let arrow = body.range(of: "->") {
                let host = String(body[..<arrow.lowerBound])
                let cont = String(body[arrow.upperBound...])
                let hostIP: String?
                let hostRange: String
                if let c = host.lastIndex(of: ":") { hostIP = String(host[..<c]); hostRange = String(host[host.index(after: c)...]) }
                else { hostIP = nil; hostRange = host }
                let hostPorts = expand(hostRange), contPorts = expand(cont)
                for (i, hp) in hostPorts.enumerated() {
                    let cp = i < contPorts.count ? contPorts[i] : contPorts.first ?? hp
                    out.append(DockerPortMapping(hostIP: hostIP, hostPort: hp, containerPort: cp, proto: proto))
                }
            } else {
                for cp in expand(body) { out.append(DockerPortMapping(hostIP: nil, hostPort: nil, containerPort: cp, proto: proto)) }
            }
        }
        return out
    }

    static func expand(_ range: String) -> [Int] {
        let parts = range.split(separator: "-")
        if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a <= b, b - a < 1000 { return Array(a...b) }
        return Int(range).map { [$0] } ?? []
    }

    struct StatsRow: Decodable { let ID: String; let Name: String; let CPUPerc: String; let MemUsage: String }
    struct Stat { let cpu: Double; let mem: String }

    static func parseStats(_ text: String) -> [String: Stat] {
        var out: [String: Stat] = [:]
        for line in text.split(separator: "\n") {
            guard let row = try? JSONDecoder().decode(StatsRow.self, from: Data(line.utf8)) else { continue }
            let cpu = Double(row.CPUPerc.replacingOccurrences(of: "%", with: "")) ?? 0
            let mem = row.MemUsage.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? row.MemUsage
            let st = Stat(cpu: cpu, mem: mem)
            out[row.ID] = st; out[row.Name] = st
        }
        return out
    }

    // MARK: actions

    public enum Action: String, Sendable { case start, stop, restart }

    public func perform(_ action: Action, on container: DockerContainer) throws {
        try Shell.run("docker", [action.rawValue, container.id], timeout: 30)
    }

    public func logs(_ container: DockerContainer, tail: Int = 200) -> String {
        let r = try? Shell.run("docker", ["logs", "--tail", String(tail), container.id], timeout: 10)
        return [r?.stdout ?? "", r?.stderr ?? ""].joined()
    }
}
