import Foundation

/// USD per 1M tokens for one model, from the models.dev catalog.
public struct ModelPrice: Sendable {
    public let modelId: String
    public let provider: String
    public var input: Double?, output: Double?, cacheRead: Double?, cacheWrite: Double?, reasoning: Double?
    public var contextLimit: Int?
    public var priced: Bool { input != nil || output != nil }

    func cost(input i: Int, output o: Int, cacheRead cr: Int, cacheWrite cw: Int, reasoning r: Int) -> Double {
        let inp: Double = input ?? 0
        let out: Double = output ?? 0
        let crRate: Double = cacheRead ?? inp
        let cwRate: Double = cacheWrite ?? inp
        let rRate: Double = reasoning ?? out
        var total: Double = Double(i) * inp
        total += Double(o) * out
        total += Double(cr) * crRate
        total += Double(cw) * cwRate
        total += Double(r) * rRate
        return total / 1_000_000
    }
}

/// Indexed view over a models.dev pricing dump (USD per 1M tokens per model).
///
/// Minions ships its own snapshot as an app resource, so pricing works fully
/// offline on a machine with none of the supported agents installed. Load
/// order, most authoritative first:
///
/// 1. Minions' own refreshed cache in Application Support (from Settings ->
///    "Refresh from models.dev").
/// 2. The bundled snapshot shipped inside the app (`Resources/models_dev_snapshot.json`).
/// 3. A cache another local tool happens to have already downloaded (Hermes,
///    TokenMon, ...) — purely a courtesy so we don't refetch what is already
///    on disk; Minions never requires any of these tools to be installed.
public final class PricingCatalog: @unchecked Sendable {
    /// Minions' own cache, written by `refresh()`. Always checked first.
    public static let ownCachePath = NSString(string: "~/Library/Application Support/Minions/models_dev.json").expandingTildeInPath

    /// Caches other local tools may have already populated. Read-only, best-effort,
    /// and never the only source: the bundled snapshot below covers the case
    /// where none of these exist.
    public static let opportunisticCachePaths = [
        "~/.hermes/models_dev_cache.json",
        "~/.cache/tokenmon/models_dev.json",
        "~/.config/tokenmon/models_dev.json",
    ].map { NSString(string: $0).expandingTildeInPath }

    public static let providerAliases: [String: String] = [
        "anthropic": "anthropic", "claude": "anthropic", "openai": "openai", "openai-api": "openai",
        "openai-codex": "openai", "azure": "azure", "deepseek": "deepseek", "moonshot": "moonshotai",
        "moonshotai": "moonshotai", "zhipu": "zhipuai", "zhipuai": "zhipuai", "google": "google",
        "gemini": "google", "vertex": "google-vertex", "bedrock": "amazon-bedrock", "groq": "groq",
        "mistral": "mistral", "xai": "xai", "openrouter": "openrouter", "opencode": "opencode",
        "opencode-go": "opencode-go", "ollama-cloud": "ollama-cloud", "ollama": "ollama-cloud",
    ]
    static let canonicalProviders = ["anthropic", "openai", "deepseek", "moonshotai", "zhipuai", "google", "xai", "mistral", "meta", "qwen", "alibaba", "opencode", "opencode-go", "groq", "together", "fireworks", "openrouter"]
    public static let subscriptionProviders: Set<String> = ["ollama-cloud", "opencode-go", "openai-codex", "claude-subscription"]
    public static let localProviders: Set<String> = ["local", "ollama-local", "lmstudio", "llamacpp", "vllm"]

    public let source: String
    private var byProvider: [String: [String: ModelPrice]] = [:]
    public private(set) var unmatched = Set<String>()
    private let lock = NSLock()

    public init(raw: [String: Any], source: String) {
        self.source = source
        index(raw)
    }

    public static func load() -> PricingCatalog {
        if let data = FileManager.default.contents(atPath: ownCachePath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return PricingCatalog(raw: json, source: ownCachePath)
        }
        if let data = try? Data(contentsOf: bundledSnapshotURL()),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return PricingCatalog(raw: json, source: "bundled snapshot")
        }
        for p in opportunisticCachePaths {
            if let data = FileManager.default.contents(atPath: p),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return PricingCatalog(raw: json, source: p)
            }
        }
        return PricingCatalog(raw: [:], source: "none")
    }

    /// The pricing snapshot built into the app bundle, refreshed at release time
    /// so a fresh install has reasonable prices even before the first network
    /// refresh. Not present outside the bundle (e.g. `swift test`) is fine;
    /// callers fall through to an opportunistic cache or an empty catalog.
    ///
    /// Resolved via `AppResources`, not the SwiftPM-synthesized `Bundle.module`
    /// — see that type's doc comment for why `Bundle.module` cannot be used
    /// safely here in a packaged, CI-built app.
    static func bundledSnapshotURL() throws -> URL {
        guard let url = AppResources.url(inResourceBundle: "Minions_MinionsCore", file: "models_dev_snapshot.json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    /// Fetches a fresh catalog from models.dev and saves it as Minions' own
    /// cache, which future launches then treat as authoritative.
    public static func refresh() async throws -> PricingCatalog {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://models.dev/api.json")!)
        try FileManager.default.createDirectory(atPath: (ownCachePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: ownCachePath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return PricingCatalog(raw: json, source: ownCachePath)
    }

    public var providerCount: Int { byProvider.count }
    public var modelCount: Int { byProvider.values.reduce(0) { $0 + $1.count } }

    private func index(_ raw: [String: Any]) {
        for (providerId, p) in raw {
            guard let provider = p as? [String: Any], let models = provider["models"] as? [String: Any] else { continue }
            var bucket = byProvider[providerId] ?? [:]
            for (modelId, m) in models {
                guard let meta = m as? [String: Any] else { continue }
                let cost = meta["cost"] as? [String: Any] ?? [:]
                let limit = meta["limit"] as? [String: Any] ?? [:]
                let price = ModelPrice(modelId: modelId, provider: providerId,
                                       input: num(cost["input"]), output: num(cost["output"]),
                                       cacheRead: num(cost["cache_read"]), cacheWrite: num(cost["cache_write"]),
                                       reasoning: num(cost["reasoning"]), contextLimit: (limit["context"] as? NSNumber)?.intValue)
                for key in Set([modelId.lowercased(), Self.normalize(modelId)]) {
                    if let existing = bucket[key], existing.priced || !price.priced { continue }
                    bucket[key] = price
                }
            }
            byProvider[providerId] = bucket
        }
    }

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    /// `deepseek/deepseek-v4-pro:0813` -> `deepseek-v4-pro`; `claude-opus-4.7` -> `claude-opus-4-7`
    public static func normalize(_ model: String) -> String {
        var m = model.trimmingCharacters(in: .whitespaces).lowercased()
        if m.hasPrefix("@"), let slash = m.firstIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        if let colon = m.lastIndex(of: ":") { m = String(m[..<colon]) }
        m = m.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-")
        return m.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func variants(_ model: String) -> [String] {
        var out: [String] = []
        let raw = model.trimmingCharacters(in: .whitespaces).lowercased()
        for c in [raw, normalize(model)] where !c.isEmpty && !out.contains(c) { out.append(c) }
        if let base = out.last {
            for suffix in ["-latest", "-preview", "-turbo"] where base.hasSuffix(suffix) {
                let t = String(base.dropLast(suffix.count))
                if !out.contains(t) { out.append(t) }
            }
        }
        return out
    }

    public func resolve(model: String, provider: String?) -> ModelPrice? {
        let keys = Self.variants(model)
        let p = (provider ?? "").lowercased()
        let mapped = Self.providerAliases[p] ?? p
        if let hit = first(mapped, keys), hit.priced { return hit }
        for c in Self.canonicalProviders { if let hit = first(c, keys), hit.priced { return hit } }
        for pid in byProvider.keys.sorted() { if let hit = first(pid, keys), hit.priced { return hit } }
        lock.lock(); unmatched.insert("\(model) (\(provider ?? "-"))"); lock.unlock()
        return nil
    }

    private func first(_ provider: String, _ keys: [String]) -> ModelPrice? {
        guard let bucket = byProvider[provider] else { return nil }
        for k in keys { if let p = bucket[k] { return p } }
        return nil
    }

    public static func billingMode(provider: String?, declared: BillingMode?) -> BillingMode {
        if let d = declared, d != .unknown { return d }
        let p = (provider ?? "").lowercased()
        if localProviders.contains(p) { return .local }
        if subscriptionProviders.contains(p) { return .subscription }
        return p.isEmpty ? .unknown : .metered
    }

    /// Fill in notional and billed cost the way TokenMon does: reported cost wins,
    /// subscription/local lanes bill zero, otherwise list price.
    public func price(_ r: UsageRecord) -> UsageRecord {
        var r = r
        let mode = Self.billingMode(provider: r.provider, declared: r.billingMode)
        r.billingMode = mode
        if let p = resolve(model: r.model, provider: r.provider) {
            r.costNotional = p.cost(input: r.input, output: r.output, cacheRead: r.cacheRead, cacheWrite: r.cacheWrite, reasoning: r.reasoning)
        } else {
            r.costNotional = nil
        }
        if mode == .subscription || mode == .local {
            r.costBilled = 0; r.costSource = .reported
        } else if let b = r.costBilled, b > 0 {
            r.costSource = .reported
        } else if let n = r.costNotional {
            r.costBilled = n; r.costSource = .computed
        } else {
            r.costSource = .unknown
        }
        return r
    }
}
