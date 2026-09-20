import Foundation
import MinionsCore

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    let p = String(repeating: " ", count: max(0, w - s.count))
    return right ? p + s : s + p
}
func row(_ cols: [String]) -> String {
    let widths = [12, 7, 9, 9, 9, 9, 5, 10, 10]
    return zip(cols, widths).enumerated().map { pad($0.element.0, $0.element.1, right: $0.offset > 0) }.joined(separator: " ")
}

// `Minions --report [days]` prints a headless usage report and exits. Useful for
// cross-checking numbers against `tokenmon cost` and for scripting.
if CommandLine.arguments.contains("--sessions") {
    let store = UsageStore()
    _ = store.refresh(); store.save()
    let sessions = (store.claude.sessions(limit: 100) + store.codex.sessions(limit: 100) + store.hermes.sessions(limit: 100) + store.pi.sessions(limit: 100))
        .sorted { $0.lastActivity > $1.lastActivity }
    print(row(["agent", "title/instance", "model", "started", "last activity", "recent?"]))
    for s in sessions {
        print(row([s.agent, (s.title ?? s.instance ?? "-"), s.model ?? "-", s.startedAt.map { Fmt.ago($0) } ?? "-", Fmt.ago(s.lastActivity), s.isRecent ? "yes" : "no"]))
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--report") {
    let days = CommandLine.arguments.dropFirst(i + 1).first.flatMap(Int.init) ?? 30
    let store = UsageStore()
    let t0 = Date()
    let added = store.refresh()
    store.save()
    let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
    print(String(format: "scan %.2fs, %d new records, %d total, catalog %@ (%d models)", Date().timeIntervalSince(t0), added, store.records.count, store.catalog.source, store.catalog.modelCount))
    print("\nlast \(days)d by agent")
    print(row(["agent", "calls", "in", "out", "cache-r", "cache-w", "hit%", "billed", "notional"]))
    for s in store.summary(since: since, groupBy: { $0.agent }) {
        print(row([s.key, "\(s.apiCalls)", Fmt.tokens(s.input), Fmt.tokens(s.output), Fmt.tokens(s.cacheRead), Fmt.tokens(s.cacheWrite), String(format: "%.0f%%", (s.cacheHitRate ?? 0) * 100), Fmt.usd(s.costBilled), Fmt.usd(s.costNotional) + (s.hasUnknownCost ? "*" : "")]))
    }
    let t = store.total(since: since)
    print(row(["TOTAL", "\(t.apiCalls)", Fmt.tokens(t.input), Fmt.tokens(t.output), Fmt.tokens(t.cacheRead), Fmt.tokens(t.cacheWrite), String(format: "%.0f%%", (t.cacheHitRate ?? 0) * 100), Fmt.usd(t.costBilled), Fmt.usd(t.costNotional)]))
    print("\ntoday: \(Fmt.usd(store.total(since: UsageStore.startOfToday()).costBilled))")
    if !store.catalog.unmatched.isEmpty { print("unpriced: \(store.catalog.unmatched.sorted().joined(separator: ", "))") }
    exit(0)
}

MinionsApp.main()
