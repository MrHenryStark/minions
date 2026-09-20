import Foundation

// MARK: - Ports

public struct ListeningPort: Identifiable, Hashable, Sendable {
    public var id: String { "\(pid):\(port):\(address)" }
    public let port: Int
    public let address: String        // "*", "127.0.0.1", "::1"
    public let pid: Int
    public let processName: String
    public var command: String?       // full command line
    public var cwd: String?
    public var startedAt: Date?
    public var container: DockerContainer?
    public var project: ProjectInfo?

    public init(port: Int, address: String, pid: Int, processName: String, command: String? = nil, cwd: String? = nil, startedAt: Date? = nil, container: DockerContainer? = nil, project: ProjectInfo? = nil) {
        self.port = port; self.address = address; self.pid = pid; self.processName = processName
        self.command = command; self.cwd = cwd; self.startedAt = startedAt; self.container = container; self.project = project
    }

    public var isLoopbackOnly: Bool { address.hasPrefix("127.") || address == "::1" || address == "localhost" }
    public var url: URL { URL(string: "http://localhost:\(port)")! }

    /// Short human label: container name, project name, or process name.
    public var label: String {
        if let c = container { return c.serviceName ?? c.name }
        if let p = project?.name { return p }
        return processName
    }

    public var kind: PortKind {
        if container != nil { return .docker }
        return PortKind.detect(processName: processName, command: command, port: port)
    }
}

public enum PortKind: String, Sendable, CaseIterable {
    case docker, node, python, database, java, go, rust, ruby, php, browser, system, other

    public static func detect(processName: String, command: String?, port: Int) -> PortKind {
        let name = processName.lowercased()
        let cmd = (command ?? "").lowercased()
        let dbPorts: Set<Int> = [5432, 3306, 6379, 27017, 9200, 5672, 9092, 1433, 8123]
        if dbPorts.contains(port) || name.contains("postgres") || name.contains("mysqld") || name.contains("redis") || name.contains("mongod") { return .database }
        if name == "node" || cmd.contains("/node ") || cmd.hasPrefix("node ") || cmd.contains("bun ") || cmd.contains("deno ") { return .node }
        if name.hasPrefix("python") || cmd.contains("uvicorn") || cmd.contains("gunicorn") || cmd.contains("manage.py") || cmd.contains("flask") { return .python }
        if name == "java" || name.contains("gradle") || name.contains("kotlin") { return .java }
        if name == "ruby" || name.contains("puma") || name.contains("rails") { return .ruby }
        if name.contains("php") { return .php }
        if name.contains("chrome") || name.contains("google") || name.contains("safari") || name.contains("firefox") || name.contains("arc") { return .browser }
        if ["rapportd", "controlce", "finder", "findersyn", "sharingd", "airplay", "cloud-dri", "identitys", "cupsd", "launchd", "airplayx"].contains(where: { name.hasPrefix($0) }) { return .system }
        return .other
    }

    public var symbol: String {
        switch self {
        case .docker: return "shippingbox"
        case .node: return "hexagon"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .database: return "cylinder"
        case .java: return "cup.and.saucer"
        case .go, .rust: return "gearshape"
        case .ruby: return "diamond"
        case .php: return "p.square"
        case .browser: return "globe"
        case .system: return "apple.logo"
        case .other: return "circle"
        }
    }
}

/// Framework / project details inferred from a process's working directory.
public struct ProjectInfo: Hashable, Sendable {
    public var name: String?
    public var framework: String?     // Vite, Next.js, Django, FastAPI, Express, ...
    public var runtime: String?       // node 22.3, python 3.12
    public var gitBranch: String?
    public var gitDirty: Int?
    public init(name: String? = nil, framework: String? = nil, runtime: String? = nil, gitBranch: String? = nil, gitDirty: Int? = nil) {
        self.name = name; self.framework = framework; self.runtime = runtime; self.gitBranch = gitBranch; self.gitDirty = gitDirty
    }
}

// MARK: - Docker

public struct DockerContainer: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String          // running, exited, paused, created
    public let status: String         // "Up 6 minutes (healthy)"
    public let ports: [DockerPortMapping]
    public let composeProject: String?
    public let serviceName: String?
    public let composeDir: String?
    public var cpuPercent: Double?
    public var memUsage: String?

    public init(id: String, name: String, image: String, state: String, status: String, ports: [DockerPortMapping], composeProject: String?, serviceName: String?, composeDir: String?, cpuPercent: Double? = nil, memUsage: String? = nil) {
        self.id = id; self.name = name; self.image = image; self.state = state; self.status = status; self.ports = ports
        self.composeProject = composeProject; self.serviceName = serviceName; self.composeDir = composeDir
        self.cpuPercent = cpuPercent; self.memUsage = memUsage
    }

    public var isRunning: Bool { state == "running" }
    public var isHealthy: Bool? {
        if status.contains("(healthy)") { return true }
        if status.contains("(unhealthy)") { return false }
        return nil
    }
    public var hostPorts: [Int] { ports.compactMap { $0.hostPort } }
}

public struct DockerPortMapping: Hashable, Sendable, Codable {
    public let hostIP: String?
    public let hostPort: Int?
    public let containerPort: Int
    public let proto: String
    public init(hostIP: String?, hostPort: Int?, containerPort: Int, proto: String) {
        self.hostIP = hostIP; self.hostPort = hostPort; self.containerPort = containerPort; self.proto = proto
    }
    public var description: String {
        if let hp = hostPort { return hp == containerPort ? "\(hp)" : "\(hp)→\(containerPort)" }
        return "\(containerPort)/\(proto)"
    }
}

public enum DockerState: Sendable, Equatable {
    case unavailable(String)   // CLI missing
    case stopped               // daemon not running
    case running
}

// MARK: - Token usage

public enum BillingMode: String, Codable, Sendable { case metered, subscription, local, unknown }
public enum CostSource: String, Codable, Sendable { case reported, computed, unknown }

/// One roll-up of token usage, matching TokenMon's `UsageRecord`.
public struct UsageRecord: Codable, Hashable, Sendable {
    public var ts: Date
    public var agent: String            // claude-code | codex | hermes
    public var instance: String?        // project slug, hermes profile
    public var sessionId: String
    public var model: String
    public var provider: String
    public var billingMode: BillingMode = .unknown
    public var task: String?
    public var apiCalls: Int = 0
    public var input: Int = 0
    public var output: Int = 0
    public var cacheRead: Int = 0
    public var cacheWrite: Int = 0
    public var reasoning: Int = 0
    public var costBilled: Double?
    public var costNotional: Double?
    public var costSource: CostSource = .unknown
    public var cwd: String?
    public var ref: String

    public init(ts: Date, agent: String, instance: String? = nil, sessionId: String, model: String, provider: String, billingMode: BillingMode = .unknown, task: String? = nil, apiCalls: Int = 0, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0, costBilled: Double? = nil, costNotional: Double? = nil, costSource: CostSource = .unknown, cwd: String? = nil, ref: String) {
        self.ts = ts; self.agent = agent; self.instance = instance; self.sessionId = sessionId; self.model = model; self.provider = provider
        self.billingMode = billingMode; self.task = task; self.apiCalls = apiCalls; self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.reasoning = reasoning
        self.costBilled = costBilled; self.costNotional = costNotional; self.costSource = costSource; self.cwd = cwd; self.ref = ref
    }

    public var totalInput: Int { input + cacheRead + cacheWrite }
    public var total: Int { totalInput + output }
    public var dedupKey: String { "\(agent)|\(ref)" }
}

/// Aggregated totals for a bucket (agent, model, day, ...).
public struct UsageSummary: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public var apiCalls = 0
    public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, reasoning = 0
    public var costBilled: Double = 0
    public var costNotional: Double = 0
    public var hasUnknownCost = false
    public var lastActivity: Date?
    public var model: String?

    public init(key: String) { self.key = key }

    public mutating func add(_ r: UsageRecord) {
        apiCalls += r.apiCalls; input += r.input; output += r.output
        cacheRead += r.cacheRead; cacheWrite += r.cacheWrite; reasoning += r.reasoning
        costBilled += r.costBilled ?? 0
        costNotional += r.costNotional ?? 0
        if r.costSource == .unknown { hasUnknownCost = true }
        if lastActivity == nil || r.ts > lastActivity! { lastActivity = r.ts; model = r.model }
    }
    public var total: Int { input + cacheRead + cacheWrite + output }
    public var cacheHitRate: Double? {
        let d = input + cacheRead
        return d > 0 ? Double(cacheRead) / Double(d) : nil
    }
}

public struct DevSession: Identifiable, Hashable, Sendable {
    public var id: String { "\(agent):\(sessionId)" }
    public let agent: String
    public let sessionId: String
    public var title: String?
    public var instance: String?
    public var model: String?
    public var cwd: String?
    public var gitBranch: String?
    public var startedAt: Date?
    public var lastActivity: Date
    public var isLive: Bool          // a process is currently attached / talking to the API
    public var costToday: Double = 0

    public init(agent: String, sessionId: String, title: String? = nil, instance: String? = nil, model: String? = nil, cwd: String? = nil, gitBranch: String? = nil, startedAt: Date? = nil, lastActivity: Date, isLive: Bool) {
        self.agent = agent; self.sessionId = sessionId; self.title = title; self.instance = instance; self.model = model
        self.cwd = cwd; self.gitBranch = gitBranch; self.startedAt = startedAt; self.lastActivity = lastActivity; self.isLive = isLive
    }
    public var isRecent: Bool { Date().timeIntervalSince(lastActivity) < 300 }
}

public struct LocalModelServer: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String            // Ollama, LM Studio
    public let reachable: Bool
    public let models: [String]
    public let detail: String?
    public init(name: String, reachable: Bool, models: [String], detail: String? = nil) {
        self.name = name; self.reachable = reachable; self.models = models; self.detail = detail
    }
}

/// An active TCP connection from a local process to an AI provider.
public struct LiveConnection: Identifiable, Hashable, Sendable {
    public var id: String { "\(pid):\(remote)" }
    public let pid: Int
    public let processName: String
    public let remote: String
    public let provider: String
    public init(pid: Int, processName: String, remote: String, provider: String) {
        self.pid = pid; self.processName = processName; self.remote = remote; self.provider = provider
    }
}

// MARK: - System

public struct SystemStats: Sendable, Equatable {
    public var cpuPercent: Double = 0
    public var memoryUsedBytes: UInt64 = 0
    public var memoryTotalBytes: UInt64 = 0
    public var memoryPressure: String = "normal"
    public var diskFreeBytes: UInt64 = 0
    public var diskTotalBytes: UInt64 = 0
    public var uptime: TimeInterval = 0
    public init() {}
    public var memoryPercent: Double { memoryTotalBytes > 0 ? Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100 : 0 }
}

// MARK: - Formatting helpers

public enum Fmt {
    public static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        case ..<1_000_000_000: return String(format: "%.2fM", Double(n) / 1_000_000)
        default: return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
    }
    public static func usd(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v < 0.01 { return "<$0.01" }
        if v < 100 { return String(format: "$%.2f", v) }
        return String(format: "$%.0f", v)
    }

    /// A cost cell for a summary row: a subscription or local lane (Codex,
    /// ollama-cloud, on-device models) always bills $0 by design, and showing
    /// a bare "$0" next to real, nonzero token counts reads as "no usage" —
    /// indistinguishable from an agent that genuinely did nothing. When that's
    /// the case, this shows the notional list-rate cost instead, tilde-prefixed
    /// to mark it as "not actually billed, but what this would have cost."
    public static func billedCell(billed: Double, notional: Double, unknown: Bool) -> String {
        if unknown { return "?" }
        if billed == 0 && notional > 0.001 { return "~\(usd(notional))" }
        return usd(billed)
    }
    public static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
    public static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
    public static func duration(_ s: TimeInterval) -> String {
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return String(format: "%dh %02dm", Int(s / 3600), Int(s.truncatingRemainder(dividingBy: 3600) / 60)) }
        return "\(Int(s / 86400))d \(Int(s.truncatingRemainder(dividingBy: 86400) / 3600))h"
    }
}
