import Foundation
import Darwin
import SwiftUI
import MinionsCore

/// Single source of truth for the UI. Collectors run on a background queue and
/// publish snapshots back on the main actor.
@MainActor
final class AppStore: ObservableObject {
    // Snapshots
    @Published var ports: [ListeningPort] = []
    @Published var dockerState: DockerState = .stopped
    @Published var containers: [DockerContainer] = []
    @Published var system = SystemStats()
    @Published var sessions: [DevSession] = []
    @Published var liveConnections: [LiveConnection] = []
    @Published var localServers: [LocalModelServer] = []
    @Published var usageToday = UsageSummary(key: "today")
    @Published var usageWeek = UsageSummary(key: "week")
    @Published var usageMonth = UsageSummary(key: "month")
    @Published var usageByAgentToday: [UsageSummary] = []
    @Published var usageByModelWeek: [UsageSummary] = []
    @Published var usageBySessionToday: [UsageSummary] = []
    @Published var dailyCost: [(day: Date, cost: Double, tokens: Int)] = []
    @Published var lastRefresh: Date?
    @Published var usageScanning = false
    @Published var errors: [String] = []

    // Preferences
    @AppStorage("showSystemPorts") var showSystemPorts = false
    @AppStorage("menuBarText") var menuBarText: MenuBarText = .spendToday
    @AppStorage("dailyBudget") var dailyBudget: Double = 0
    @AppStorage("watchedPorts") var watchedPortsRaw = "3000,5173,8000,8080"
    @AppStorage("fastPollSeconds") var fastPoll: Double = 3
    @AppStorage("slowPollSeconds") var slowPoll: Double = 30

    enum MenuBarText: String, CaseIterable, Identifiable {
        case none, spendToday, portCount, both
        var id: String { rawValue }
        var label: String {
            switch self { case .none: return "Icon only"; case .spendToday: return "Today's spend"; case .portCount: return "Listening ports"; case .both: return "Spend + ports" }
        }
    }

    let usage = UsageStore()
    let portsCollector = PortsCollector()
    let docker = DockerCollector()
    let projects = ProjectCollector()
    let sysStats = SystemStatsCollector()
    let live = LiveConnectionsCollector()

    private let queue = DispatchQueue(label: "minions.collect", qos: .utility)
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var fileWatchers: [DispatchSourceFileSystemObject] = []
    var isVisible = false { didSet { if isVisible != oldValue { reschedule(); if isVisible { refreshFast() } } } }

    init() {
        reschedule()
        refreshFast()
        refreshUsage()
        watchUsageDirs()
    }

    var watchedPorts: Set<Int> { Set(watchedPortsRaw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }) }

    var menuBarTitle: String {
        let spend = Fmt.usd(usageToday.costBilled)
        let n = "\(ports.count)"
        switch menuBarText {
        case .none: return ""
        case .spendToday: return spend
        case .portCount: return n
        case .both: return "\(spend) · \(n)"
        }
    }

    var overBudget: Bool { dailyBudget > 0 && usageToday.costBilled >= dailyBudget }
    var nearBudget: Bool { dailyBudget > 0 && usageToday.costBilled >= dailyBudget * 0.8 }

    /// Ports on the watch list held by something other than a dev process.
    var portConflicts: [ListeningPort] {
        ports.filter { watchedPorts.contains($0.port) && ($0.kind == .system || $0.kind == .browser) }
    }

    // MARK: scheduling

    private func reschedule() {
        fastTimer?.invalidate(); slowTimer?.invalidate()
        let interval = isVisible ? fastPoll : slowPoll
        fastTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFast() }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: isVisible ? 20 : 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUsage() }
        }
    }

    /// Ports, Docker, system, live connections. Cheap enough to run every few seconds.
    func refreshFast() {
        let showSystem = showSystemPorts
        queue.async { [self] in
            var errs: [String] = []
            var ports: [ListeningPort] = []
            do { ports = try portsCollector.collect(includeSystem: showSystem) } catch { errs.append("lsof: \(error)") }
            let snap = docker.collect(withStats: true)
            let byHostPort: [Int: DockerContainer] = Dictionary(snap.containers.filter(\.isRunning).flatMap { c in c.hostPorts.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
            ports = ports.map { p in
                var p = p
                if p.processName.hasPrefix("com.docke") || p.processName.hasPrefix("docker") || p.processName.hasPrefix("vpnkit") { p.container = byHostPort[p.port] }
                if p.container == nil, let cwd = p.cwd { p.project = projects.info(forDirectory: cwd, command: p.command) }
                return p
            }
            let sys = sysStats.collect()
            let conns = live.collect()
            DispatchQueue.main.async {
                self.ports = ports
                self.dockerState = snap.state
                self.containers = snap.containers
                self.system = sys
                self.liveConnections = conns
                self.lastRefresh = Date()
                self.errors = errs
                self.markLiveSessions()
            }
        }
    }

    /// Transcript scan + aggregation. First run may take a few seconds on a large history.
    func refreshUsage() {
        guard !usageScanning else { return }
        usageScanning = true
        queue.async { [self] in
            usage.refresh()
            usage.save()
            let today = UsageStore.startOfToday(), week = UsageStore.startOfWeek(), month = UsageStore.startOfMonth()
            let t = usage.total(since: today), w = usage.total(since: week), m = usage.total(since: month)
            let byAgent = usage.summary(since: today) { $0.agent }
            let byModel = usage.summary(since: week) { "\($0.model)" }
            let bySession = usage.summary(since: today) { "\($0.agent):\($0.sessionId)" }
            let daily = usage.daily(days: 30)
            var sessions = usage.claude.sessions(limit: 40) + usage.codex.sessions(limit: 20) + usage.hermes.sessions(limit: 20) + usage.pi.sessions(limit: 20)
            let cost = Dictionary(bySession.map { ($0.key, $0.costBilled) }, uniquingKeysWith: { a, _ in a })
            for i in sessions.indices { sessions[i].costToday = cost[sessions[i].id] ?? 0 }
            sessions.sort { $0.lastActivity > $1.lastActivity }
            Task { @MainActor in
                self.usageToday = t; self.usageWeek = w; self.usageMonth = m
                self.usageByAgentToday = byAgent; self.usageByModelWeek = byModel; self.usageBySessionToday = bySession
                self.dailyCost = daily
                self.sessions = sessions
                self.markLiveSessions()
                self.usageScanning = false
                self.localServers = await LocalServersCollector.collect()
            }
        }
    }

    /// A session is "live" when a process is currently connected to its provider
    /// and the transcript was touched in the last few minutes.
    private func markLiveSessions() {
        let liveProviders = Set(liveConnections.map(\.provider))
        for i in sessions.indices {
            let s = sessions[i]
            // Claude Code and Codex always ride one provider; Hermes and pi can
            // switch providers mid-session, so their own reader already set
            // `isLive` as best it can and we only refine, never clear it.
            let provider = s.agent == "claude-code" ? "anthropic" : s.agent == "codex" ? "openai" : nil
            sessions[i].isLive = s.isRecent && (provider.map { liveProviders.contains($0) } ?? s.isLive)
        }
    }

    private func watchUsageDirs() {
        for dir in [usage.claude.projectsDir, usage.codex.home + "/sessions"] {
            let fd = Darwin.open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib], queue: queue)
            var pending = false
            src.setEventHandler { [weak self] in
                guard !pending else { return }
                pending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pending = false; self?.refreshUsage() }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            fileWatchers.append(src)
        }
    }

    // MARK: actions

    func open(_ port: ListeningPort) { NSWorkspace.shared.open(port.url) }
    func copyURL(_ port: ListeningPort) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(port.url.absoluteString, forType: .string) }
    func revealCwd(_ port: ListeningPort) { if let c = port.cwd { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c)]) } }
    func openInTerminal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let term = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()); return
            }
        }
        NSWorkspace.shared.open(url)
    }
    func kill(_ port: ListeningPort, force: Bool = false) {
        queue.async { [self] in
            try? portsCollector.kill(pid: port.pid, force: force)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refreshFast() }
        }
    }
    func docker(_ action: DockerCollector.Action, _ c: DockerContainer) {
        queue.async { [self] in
            try? docker.perform(action, on: c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshFast() }
        }
    }
    func dockerLogs(_ c: DockerContainer, completion: @escaping (String) -> Void) {
        queue.async { [self] in
            let text = docker.logs(c, tail: 300)
            DispatchQueue.main.async { completion(text) }
        }
    }
    func connectionString(for port: ListeningPort) -> String? {
        let name = (port.container?.image ?? port.processName).lowercased()
        switch port.port {
        case 5432, 5433, 5434, 5435: return "postgresql://postgres:postgres@localhost:\(port.port)/postgres"
        case 3306: return "mysql://root@localhost:\(port.port)/"
        case 6379: return "redis://localhost:\(port.port)"
        case 27017: return "mongodb://localhost:\(port.port)"
        default:
            if name.contains("postgres") { return "postgresql://postgres:postgres@localhost:\(port.port)/postgres" }
            if name.contains("redis") { return "redis://localhost:\(port.port)" }
            if name.contains("mysql") || name.contains("maria") { return "mysql://root@localhost:\(port.port)/" }
            if name.contains("mongo") { return "mongodb://localhost:\(port.port)" }
            return nil
        }
    }
}
