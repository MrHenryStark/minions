import SwiftUI
import MinionsCore

/// The compact view under the menu bar icon: what matters right now, nothing else.
struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            SystemStrip()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !store.portConflicts.isEmpty { conflicts }
                    section("Ports", count: store.ports.count) {
                        if store.ports.isEmpty { empty("Nothing listening") }
                        ForEach(store.ports.prefix(10)) { p in PortRow(port: p, compact: true) }
                        if store.ports.count > 10 { more("\(store.ports.count - 10) more in dashboard") }
                    }
                    section("Docker", count: store.containers.filter(\.isRunning).count) {
                        switch store.dockerState {
                        case .unavailable: empty("Docker CLI not found")
                        case .stopped: empty("Docker is not running")
                        case .running:
                            let running = store.containers.filter(\.isRunning)
                            if running.isEmpty { empty("No running containers") }
                            ForEach(running.prefix(6)) { c in ContainerRow(container: c, compact: true) }
                        }
                    }
                    section("AI usage today", trailing: Fmt.usd(store.usageToday.costBilled)) {
                        if store.usageByAgentToday.isEmpty { empty(store.usageScanning ? "Scanning transcripts…" : "No usage yet today") }
                        ForEach(store.usageByAgentToday) { s in UsageRow(summary: s, live: store.liveConnections.contains { $0.provider == Self.provider(for: s.key) }) }
                        if store.dailyBudget > 0 { BudgetBar(spent: store.usageToday.costBilled, budget: store.dailyBudget) }
                    }
                    // The single most recent session per agent, regardless of
                    // how long ago that was: a rollout or transcript file's
                    // mtime only updates when its agent actually writes to
                    // disk, which can lag real interaction by a while, so a
                    // hard "last 5 minutes" filter here would routinely hide
                    // agents that are in fact the ones you're using right now.
                    // SessionRow's dot color still tells recent apart from stale.
                    let recentPerAgent = Dictionary(grouping: store.sessions, by: \.agent)
                        .values.compactMap { $0.max { $0.lastActivity < $1.lastActivity } }
                        .sorted { $0.lastActivity > $1.lastActivity }
                    if !recentPerAgent.isEmpty {
                        section("Recent sessions", count: recentPerAgent.count) {
                            ForEach(recentPerAgent.prefix(4)) { s in SessionRow(session: s, compact: true) }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 520)
            Divider()
            footer
        }
        .onAppear { store.isVisible = true }
        .onDisappear { store.isVisible = false }
    }

    static func provider(for agent: String) -> String { agent == "claude-code" ? "anthropic" : agent == "codex" ? "openai" : agent }

    var conflicts: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.portConflicts) { p in
                Label("Port \(p.port) is held by \(p.processName)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
        }
    }

    var footer: some View {
        HStack {
            Button { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) } label: { Label("Dashboard", systemImage: "rectangle.3.group") }
            Spacer()
            if let t = store.lastRefresh { Text(Fmt.ago(t) + " ago").font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
            SettingsLink { Image(systemName: "gearshape") }
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    func section<C: View>(_ title: String, count: Int? = nil, trailing: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.uppercased()).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                if let c = count { Text("\(c)").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                Spacer()
                if let t = trailing { Text(t).font(.caption).fontWeight(.semibold).monospacedDigit() }
            }
            content()
        }
    }
    func empty(_ s: String) -> some View { Text(s).font(.callout).foregroundStyle(.tertiary).padding(.vertical, 2) }
    func more(_ s: String) -> some View { Text(s).font(.caption2).foregroundStyle(.tertiary) }
}

struct SystemStrip: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 14) {
            stat("cpu", String(format: "%.0f%%", store.system.cpuPercent), warn: store.system.cpuPercent > 80)
            stat("memorychip", String(format: "%.0f%%", store.system.memoryPercent), warn: store.system.memoryPressure != "normal")
            stat("internaldrive", Fmt.bytes(store.system.diskFreeBytes) + " free", warn: store.system.diskFreeBytes < 10_000_000_000)
            Spacer()
            ForEach(store.localServers.filter(\.reachable)) { s in
                Label("\(s.name) \(s.models.count)", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.caption).monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
    func stat(_ icon: String, _ v: String, warn: Bool) -> some View {
        Label(v, systemImage: icon).foregroundStyle(warn ? .orange : .secondary)
    }
}

struct PortRow: View {
    @EnvironmentObject var store: AppStore
    let port: ListeningPort
    var compact = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: port.kind.symbol).frame(width: 16).foregroundStyle(color)
            Text(String(port.port)).font(.system(.body, design: .monospaced)).fontWeight(.medium).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(port.label).lineLimit(1)
                    if let c = port.container { tag(c.composeProject ?? "docker", .cyan) }
                    if let f = port.project?.framework { tag(f, .purple) }
                    if let b = port.project?.gitBranch { tag(b + ((port.project?.gitDirty ?? 0) > 0 ? "*" : ""), .secondary) }
                }
                if !compact || hover {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if port.isLoopbackOnly { Image(systemName: "lock").font(.caption2).foregroundStyle(.tertiary).help("Bound to loopback only") }
            if hover || !compact { actions }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { menu }
    }

    var color: Color {
        switch port.kind { case .docker: return .cyan; case .database: return .orange; case .node: return .green; case .python: return .yellow; case .browser, .system: return .secondary; default: return .primary }
    }
    var detail: String {
        var parts: [String] = ["pid \(port.pid)", port.processName]
        if let c = port.container { parts.append(c.image); parts.append(c.status) }
        else if let cwd = port.cwd { parts.append(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        if let s = port.startedAt { parts.append("up \(Fmt.duration(Date().timeIntervalSince(s)))") }
        return parts.joined(separator: " · ")
    }
    func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1).background(c.opacity(0.15), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(c)
    }
    var actions: some View {
        HStack(spacing: 6) {
            Button { store.open(port) } label: { Image(systemName: "safari") }.help("Open in browser")
            Button { store.copyURL(port) } label: { Image(systemName: "doc.on.doc") }.help("Copy URL")
            if port.container == nil {
                Button(role: .destructive) { store.kill(port) } label: { Image(systemName: "xmark.circle") }.help("Kill process")
            }
        }.buttonStyle(.borderless).font(.caption)
    }
    @ViewBuilder var menu: some View {
        Button("Open http://localhost:\(port.port)") { store.open(port) }
        Button("Copy URL") { store.copyURL(port) }
        if let cs = store.connectionString(for: port) {
            Button("Copy connection string") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cs, forType: .string) }
        }
        if let cwd = port.cwd {
            Divider()
            Button("Reveal in Finder") { store.revealCwd(port) }
            Button("Open in Terminal") { store.openInTerminal(cwd) }
            Button("Open in Editor") { store.openInEditor(cwd) }
        }
        if let c = port.container {
            Divider()
            Button("Restart container") { store.docker(.restart, c) }
            Button("Stop container") { store.docker(.stop, c) }
        } else {
            Divider()
            Button("Kill (SIGTERM)") { store.kill(port) }
            Button("Force kill (SIGKILL)") { store.kill(port, force: true) }
        }
    }
}

struct ContainerRow: View {
    @EnvironmentObject var store: AppStore
    let container: DockerContainer
    var compact = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(container.isRunning ? (container.isHealthy == false ? Color.red : Color.green) : Color.secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(container.serviceName ?? container.name).fontWeight(.medium).lineLimit(1)
                    if let p = container.composeProject { Text(p).font(.caption2).foregroundStyle(.secondary) }
                }
                Text([container.image, container.ports.map(\.description).joined(separator: " "), container.status].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let cpu = container.cpuPercent, container.isRunning {
                Text(String(format: "%.0f%% · %@", cpu, container.memUsage ?? "")).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if hover || !compact {
                HStack(spacing: 6) {
                    if container.isRunning {
                        Button { store.docker(.restart, container) } label: { Image(systemName: "arrow.clockwise") }.help("Restart")
                        Button { store.docker(.stop, container) } label: { Image(systemName: "stop.circle") }.help("Stop")
                    } else {
                        Button { store.docker(.start, container) } label: { Image(systemName: "play.circle") }.help("Start")
                    }
                }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.vertical, 2).contentShape(Rectangle()).onHover { hover = $0 }
        .contextMenu {
            if let d = container.composeDir {
                Button("Open compose dir in Terminal") { store.openInTerminal(d) }
                Button("Reveal compose dir") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d)]) }
            }
            ForEach(container.hostPorts, id: \.self) { p in Button("Open localhost:\(p)") { NSWorkspace.shared.open(URL(string: "http://localhost:\(p)")!) } }
        }
    }
}

struct UsageRow: View {
    let summary: UsageSummary
    var live = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(live ? Color.green : Color.clear).overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: live ? 0 : 1)).frame(width: 8, height: 8)
                .help(live ? "Talking to the API right now" : "Idle")
            Text(AgentName.pretty(summary.key)).frame(width: 90, alignment: .leading)
            Text(summary.model.map { PricingCatalog.normalize($0) } ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("\(Fmt.tokens(summary.total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let hr = summary.cacheHitRate { Text(String(format: "%.0f%% cache", hr * 100)).font(.caption2).foregroundStyle(.tertiary) }
            Text(summary.hasUnknownCost ? "?" : Fmt.usd(summary.costBilled)).monospacedDigit().fontWeight(.medium).frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

enum AgentName {
    static func pretty(_ key: String) -> String {
        switch key { case "claude-code": return "Claude Code"; case "codex": return "Codex"; case "hermes": return "Hermes"; case "pi": return "Pi"; default: return key }
    }
}

struct BudgetBar: View {
    let spent: Double, budget: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: min(spent, budget), total: budget).tint(spent >= budget ? .red : spent >= budget * 0.8 ? .orange : .accentColor)
            Text("\(Fmt.usd(spent)) of \(Fmt.usd(budget)) daily budget").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var store: AppStore
    let session: DevSession
    var compact = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(session.isLive ? Color.green : session.isRecent ? Color.yellow : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(AgentName.pretty(session.agent)).fontWeight(.medium)
                    if let t = session.title ?? session.instance { Text(t).lineLimit(1).foregroundStyle(.secondary) }
                }
                HStack(spacing: 4) {
                    if let m = session.model { Text(PricingCatalog.normalize(m)) }
                    if let c = session.cwd { Text(c.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1) }
                    if let b = session.gitBranch { Text("⎇ \(b)") }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if session.costToday > 0 { Text(Fmt.usd(session.costToday)).font(.caption).monospacedDigit() }
            Text(Fmt.ago(session.lastActivity)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let c = session.cwd {
                Button("Open in Terminal") { store.openInTerminal(c) }
                Button("Open in Editor") { store.openInEditor(c) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c)]) }
            }
        }
    }
}
