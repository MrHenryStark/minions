import Foundation

/// Ollama and LM Studio resident models. An absent server is a state, not an error.
public enum LocalServersCollector {
    public static func collect() async -> [LocalModelServer] {
        async let ollama = probe(name: "Ollama", url: "http://127.0.0.1:11434/api/ps") { json in
            ((json["models"] as? [[String: Any]]) ?? []).compactMap { m in
                guard let n = m["name"] as? String else { return nil }
                let size = (m["size_vram"] as? NSNumber)?.uint64Value ?? (m["size"] as? NSNumber)?.uint64Value
                return size.map { "\(n) · \(Fmt.bytes($0))" } ?? n
            }
        }
        async let lm = probe(name: "LM Studio", url: "http://127.0.0.1:1234/v1/models") { json in
            ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        }
        return await [ollama, lm]
    }

    static func probe(name: String, url: String, parse: ([String: Any]) -> [String]) async -> LocalModelServer {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 1.5
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let models = parse(json)
            return LocalModelServer(name: name, reachable: true, models: models, detail: models.isEmpty ? "idle, nothing loaded" : "\(models.count) loaded")
        } catch {
            return LocalModelServer(name: name, reachable: false, models: [], detail: "not running")
        }
    }
}

/// Established TCP connections to AI providers, which tells us which agent is
/// mid-request right now. Token counts never come from the network (TLS).
public struct LiveConnectionsCollector: Sendable {
    public init() {}
    public static let providerHosts: [(String, String)] = [
        ("api.anthropic.com", "anthropic"), ("api.openai.com", "openai"), ("chatgpt.com", "openai"),
        ("generativelanguage.googleapis.com", "google"), ("api.deepseek.com", "deepseek"),
        ("openrouter.ai", "openrouter"), ("api.mistral.ai", "mistral"), ("api.x.ai", "xai"), ("ollama.com", "ollama-cloud"),
    ]

    public func collect() -> [LiveConnection] {
        // -n would hide hostnames; we need them to identify providers, so resolve via lsof's own lookup.
        guard let r = try? Shell.run("lsof", ["-iTCP", "-sTCP:ESTABLISHED", "-P", "-F", "pcn"], timeout: 8) else { return [] }
        return Self.parse(r.stdout)
    }

    public static func parse(_ text: String) -> [LiveConnection] {
        var out: [LiveConnection] = []
        var seen = Set<String>()
        var pid = 0, cmd = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let v = String(line.dropFirst())
            switch tag {
            case "p": pid = Int(v) ?? 0
            case "c": cmd = v
            case "n":
                guard let arrow = v.range(of: "->") else { continue }
                let remote = String(v[arrow.upperBound...])
                for (host, provider) in providerHosts where remote.contains(host) {
                    if seen.insert("\(pid):\(provider)").inserted {
                        out.append(LiveConnection(pid: pid, processName: cmd, remote: remote, provider: provider))
                    }
                }
            default: break
            }
        }
        return out
    }
}
