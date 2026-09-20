import SwiftUI
import Charts
import MinionsCore

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview, ports, docker, tokens, sessions
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self { case .overview: return "rectangle.3.group"; case .ports: return "network"; case .docker: return "shippingbox"; case .tokens: return "dollarsign.circle"; case .sessions: return "terminal" }
    }
}

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab: DashboardTab = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardTab.allCases, selection: $tab) { t in
                Label(t.label, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            Group {
                switch tab {
                case .overview: OverviewPane()
                case .ports: PortsPane()
                case .docker: DockerPane()
                case .tokens: TokensPane()
                case .sessions: SessionsPane()
                }
            }
            .navigationTitle(tab.label)
        }
        .toolbar {
            ToolbarItem { Button { store.refreshFast(); store.refreshUsage() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh now") }
        }
        .onAppear { store.isVisible = true }
        .onDisappear { store.isVisible = false }
        .frame(minWidth: 820, minHeight: 520)
    }
}

// MARK: - Overview

struct OverviewPane: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    StatTile(title: "Today", value: Fmt.usd(store.usageToday.costBilled), sub: "\(Fmt.tokens(store.usageToday.total)) tokens")
                    StatTile(title: "This week", value: Fmt.usd(store.usageWeek.costBilled), sub: "\(store.usageWeek.apiCalls) calls")
                    StatTile(title: "This month", value: Fmt.usd(store.usageMonth.costBilled), sub: "\(Fmt.tokens(store.usageMonth.total)) tokens")
                    StatTile(title: "Listening", value: "\(store.ports.count)", sub: "\(store.containers.filter(\.isRunning).count) containers")
                    StatTile(title: "CPU / Mem", value: String(format: "%.0f%% / %.0f%%", store.system.cpuPercent, store.system.memoryPercent), sub: store.system.memoryPressure + " pressure")
                }
                GroupBox("Spend, last 30 days") {
                    Chart(store.dailyCost, id: \.day) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("USD", d.cost))
                            .foregroundStyle(d.cost > 0 && store.dailyBudget > 0 && d.cost > store.dailyBudget ? Color.red : Color.accentColor)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .frame(height: 160)
                }
                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Ports") {
                        VStack(alignment: .leading, spacing: 2) {
                            if store.ports.isEmpty { Text("Nothing listening").foregroundStyle(.tertiary) }
                            ForEach(store.ports.prefix(12)) { PortRow(port: $0, compact: true) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Sessions") {
                        VStack(alignment: .leading, spacing: 2) {
                            if store.sessions.isEmpty { Text("No sessions").foregroundStyle(.tertiary) }
                            ForEach(store.sessions.prefix(8)) { SessionRow(session: $0, compact: true) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !store.errors.isEmpty {
                    ForEach(store.errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
                }
            }
            .padding(20)
        }
    }
}

struct StatTile: View {
    let title: String, value: String, sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title2).fontWeight(.semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Ports

struct PortsPane: View {
    @EnvironmentObject var store: AppStore
    @State private var filter = ""
    var filtered: [ListeningPort] {
        guard !filter.isEmpty else { return store.ports }
        let f = filter.lowercased()
        return store.ports.filter { String($0.port).contains(f) || $0.label.lowercased().contains(f) || $0.processName.lowercased().contains(f) || ($0.cwd ?? "").lowercased().contains(f) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter by port, name, path", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Toggle("Show system ports", isOn: $store.showSystemPorts).toggleStyle(.checkbox).onChange(of: store.showSystemPorts) { _, _ in store.refreshFast() }
                Spacer()
                Text("\(filtered.count) listening").foregroundStyle(.secondary).font(.caption)
            }.padding(12)
            Divider()
            Table(filtered) {
                TableColumn("Port") { p in Text(String(p.port)).monospacedDigit() }.width(60)
                TableColumn("Name") { p in HStack(spacing: 4) { Image(systemName: p.kind.symbol).foregroundStyle(.secondary); Text(p.label) } }.width(min: 120, ideal: 180)
                TableColumn("Kind") { p in Text(p.container != nil ? "docker" : (p.project?.framework ?? p.kind.rawValue)) }.width(90)
                TableColumn("Bind") { p in Text(p.address) }.width(80)
                TableColumn("PID") { p in Text(String(p.pid)).monospacedDigit() }.width(60)
                TableColumn("Branch") { p in Text(p.project?.gitBranch.map { $0 + (((p.project?.gitDirty ?? 0) > 0) ? " *\(p.project!.gitDirty!)" : "") } ?? "") }.width(120)
                TableColumn("Where") { p in Text(p.container.map { "\($0.name) · \($0.image)" } ?? (p.cwd ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1) }
                TableColumn("Up") { p in Text(p.startedAt.map { Fmt.duration(Date().timeIntervalSince($0)) } ?? "") }.width(70)
                TableColumn("") { p in PortActions(port: p) }.width(90)
            }
            .contextMenu(forSelectionType: ListeningPort.ID.self) { ids in
                if let id = ids.first, let p = store.ports.first(where: { $0.id == id }) { PortRow(port: p).menu }
            }
        }
    }
}

struct PortActions: View {
    @EnvironmentObject var store: AppStore
    let port: ListeningPort
    var body: some View {
        HStack(spacing: 8) {
            Button { store.open(port) } label: { Image(systemName: "safari") }.help("Open")
            Button { store.copyURL(port) } label: { Image(systemName: "doc.on.doc") }.help("Copy URL")
            if let cwd = port.cwd { Button { store.openInTerminal(cwd) } label: { Image(systemName: "terminal") }.help("Terminal here") }
            if port.container == nil { Button { store.kill(port) } label: { Image(systemName: "xmark.circle") }.help("Kill") }
        }.buttonStyle(.borderless)
    }
}

// MARK: - Docker

struct DockerPane: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: DockerContainer?
    @State private var logs = ""
    var grouped: [(String, [DockerContainer])] {
        Dictionary(grouping: store.containers) { $0.composeProject ?? "standalone" }.sorted { $0.key < $1.key }
    }
    var body: some View {
        HSplitView {
            List(selection: $selected) {
                switch store.dockerState {
                case .unavailable(let why): Text(why).foregroundStyle(.secondary)
                case .stopped: Label("Docker is not running", systemImage: "moon.zzz").foregroundStyle(.secondary)
                case .running:
                    ForEach(grouped, id: \.0) { project, list in
                        Section(header: HStack { Text(project); Spacer(); if let d = list.first?.composeDir { Button("Terminal") { store.openInTerminal(d) }.buttonStyle(.link).font(.caption) } }) {
                            ForEach(list) { c in ContainerRow(container: c).tag(c) }
                        }
                    }
                }
            }
            .frame(minWidth: 380)
            VStack(alignment: .leading, spacing: 8) {
                if let c = selected {
                    HStack {
                        Text(c.name).font(.headline)
                        Text(c.image).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reload logs") { load(c) }
                    }
                    Text(c.status + (c.ports.isEmpty ? "" : " · " + c.ports.map(\.description).joined(separator: ", "))).font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(logs.isEmpty ? "No output" : logs).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(.quaternary.opacity(0.3))
                } else {
                    Text("Select a container to tail its logs").foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(12)
            .frame(minWidth: 300)
        }
        .onChange(of: selected) { _, c in if let c { load(c) } else { logs = "" } }
    }
    func load(_ c: DockerContainer) { logs = "Loading…"; store.dockerLogs(c) { logs = $0 } }
}

// MARK: - Tokens

struct TokensPane: View {
    @EnvironmentObject var store: AppStore
    @State private var range: Range = .today
    enum Range: String, CaseIterable, Identifiable { case today, week, month; var id: String { rawValue } }

    var since: Date { switch range { case .today: return UsageStore.startOfToday(); case .week: return UsageStore.startOfWeek(); case .month: return UsageStore.startOfMonth() } }
    var byAgent: [UsageSummary] { store.usage.summary(since: since) { $0.agent } }
    var byModel: [UsageSummary] { store.usage.summary(since: since) { "\($0.model) · \($0.provider)" } }
    var byProject: [UsageSummary] { store.usage.summary(since: since) { ($0.cwd ?? $0.instance ?? "-").replacingOccurrences(of: NSHomeDirectory(), with: "~") } }
    var total: UsageSummary { store.usage.total(since: since) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented).frame(width: 240)
                    Spacer()
                    if store.usageScanning { ProgressView().controlSize(.small); Text("scanning").font(.caption).foregroundStyle(.secondary) }
                    Text("catalog: \(store.usage.catalog.source == "none" ? "none" : "\(store.usage.catalog.modelCount) models")").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    StatTile(title: "Billed", value: Fmt.usd(total.costBilled), sub: total.hasUnknownCost ? "some models unpriced" : "at list rates")
                    StatTile(title: "Notional", value: Fmt.usd(total.costNotional), sub: "if all lanes were metered")
                    StatTile(title: "Input", value: Fmt.tokens(total.input + total.cacheRead + total.cacheWrite), sub: String(format: "%.0f%% cache hits", (total.cacheHitRate ?? 0) * 100))
                    StatTile(title: "Output", value: Fmt.tokens(total.output), sub: "\(Fmt.tokens(total.reasoning)) reasoning")
                    StatTile(title: "Calls", value: "\(total.apiCalls)", sub: "API requests")
                }
                GroupBox("Daily spend by agent") {
                    let days = range == .month ? 30 : range == .week ? 7 : 1
                    let rows: [AgentDay] = ["claude-code", "codex", "hermes", "pi"].flatMap { a in store.usage.daily(days: days, agent: a).map { AgentDay(agent: a, day: $0.day, cost: $0.cost) } }
                    Chart(rows) { r in
                        BarMark(x: .value("Day", r.day, unit: .day), y: .value("USD", r.cost)).foregroundStyle(by: .value("Agent", AgentName.pretty(r.agent)))
                    }
                    .frame(height: 140)
                }
                usageTable("By agent", byAgent) { AgentName.pretty($0) }
                usageTable("By model", byModel) { $0 }
                usageTable("By project", byProject) { $0 }
                if !store.usage.catalog.unmatched.isEmpty {
                    GroupBox("Unpriced models") { Text(store.usage.catalog.unmatched.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                }
                if !store.localServers.isEmpty {
                    GroupBox("Local model servers") {
                        ForEach(store.localServers) { s in
                            HStack { Circle().fill(s.reachable ? Color.green : Color.secondary.opacity(0.3)).frame(width: 8, height: 8); Text(s.name).fontWeight(.medium); Text(s.detail ?? "").foregroundStyle(.secondary); Spacer() }
                            ForEach(s.models, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).padding(.leading, 16) }
                        }
                    }
                }
            }.padding(20)
        }
    }

    func usageTable(_ title: String, _ rows: [UsageSummary], name: @escaping (String) -> String) -> some View {
        GroupBox(title) {
            Table(rows) {
                TableColumn("Name") { Text(name($0.key)).lineLimit(1) }
                TableColumn("Calls") { Text("\($0.apiCalls)").monospacedDigit() }.width(60)
                TableColumn("Input") { Text(Fmt.tokens($0.input)).monospacedDigit() }.width(70)
                TableColumn("Cache r/w") { Text("\(Fmt.tokens($0.cacheRead)) / \(Fmt.tokens($0.cacheWrite))").monospacedDigit() }.width(120)
                TableColumn("Output") { Text(Fmt.tokens($0.output)).monospacedDigit() }.width(70)
                TableColumn("Hit") { Text($0.cacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "").monospacedDigit() }.width(50)
                TableColumn("Cost") { s in
                    let cell = Fmt.billedCell(billed: s.costBilled, notional: s.costNotional, unknown: s.hasUnknownCost)
                    Text(cell).monospacedDigit().fontWeight(.medium)
                        .foregroundStyle(cell.hasPrefix("~") ? .secondary : .primary)
                        .help(cell.hasPrefix("~") ? "Runs on a flat subscription, so it's billed $0 — this is what it would cost at list API rates" : "")
                }.width(70)
                TableColumn("Last") { Text($0.lastActivity.map { Fmt.ago($0) } ?? "") }.width(50)
            }
            .frame(height: CGFloat(min(max(rows.count, 1), 8)) * 26 + 30)
        }
    }
}

struct AgentDay: Identifiable { let agent: String; let day: Date; let cost: Double; var id: String { agent + day.description } }

// MARK: - Sessions

struct SessionsPane: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Table(store.sessions) {
            TableColumn("") { s in Circle().fill(s.isLive ? Color.green : s.isRecent ? Color.yellow : Color.secondary.opacity(0.3)).frame(width: 8, height: 8) }.width(14)
            TableColumn("Agent") { Text(AgentName.pretty($0.agent)) }.width(90)
            TableColumn("Title") { Text($0.title ?? $0.instance ?? "").lineLimit(1) }
            TableColumn("Model") { Text($0.model.map { PricingCatalog.normalize($0) } ?? "") }.width(140)
            TableColumn("Directory") { Text(($0.cwd ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1) }
            TableColumn("Branch") { Text($0.gitBranch ?? "") }.width(100)
            TableColumn("Today") { Text($0.costToday > 0 ? Fmt.usd($0.costToday) : "").monospacedDigit() }.width(60)
            TableColumn("Last") { Text(Fmt.ago($0.lastActivity)).monospacedDigit() }.width(50)
            TableColumn("") { s in
                HStack(spacing: 8) {
                    if let c = s.cwd {
                        Button { store.openInTerminal(c) } label: { Image(systemName: "terminal") }
                        Button { store.openInEditor(c) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    }
                }.buttonStyle(.borderless)
            }.width(60)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var refreshing = false
    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Show in menu bar", selection: $store.menuBarText) { ForEach(AppStore.MenuBarText.allCases) { Text($0.label).tag($0) } }
                Toggle("Include system ports", isOn: $store.showSystemPorts)
            }
            Section("Polling") {
                Slider(value: $store.fastPoll, in: 1...10, step: 1) { Text("While open: \(Int(store.fastPoll))s") }
                Slider(value: $store.slowPoll, in: 10...120, step: 10) { Text("In background: \(Int(store.slowPoll))s") }
            }
            Section("Alerts") {
                TextField("Daily budget (USD, 0 = off)", value: $store.dailyBudget, format: .number)
                TextField("Watched ports (comma separated)", text: $store.watchedPortsRaw)
                Text("Watched ports warn when a browser or system process, not a dev server, holds them.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Pricing catalog") {
                LabeledContent("Source", value: store.usage.catalog.source.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Button(refreshing ? "Downloading…" : "Refresh from models.dev") {
                    refreshing = true
                    Task { _ = try? await PricingCatalog.refresh(); refreshing = false }
                }.disabled(refreshing)
                Text("The refreshed catalog is used after the next app launch.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Usage cache", value: store.usage.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                LabeledContent("Last scan", value: String(format: "%.2fs", store.usage.lastScanDuration))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
    }
}
