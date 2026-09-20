import Foundation

/// Infers what a process is (framework, project name, git state) from its cwd.
/// Results are cached per directory because they change rarely and the git
/// call is the expensive part.
public final class ProjectCollector: @unchecked Sendable {
    private var cache: [String: (ProjectInfo, Date)] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 20) { self.ttl = ttl }

    public func info(forDirectory dir: String, command: String? = nil) -> ProjectInfo {
        lock.lock()
        if let (info, at) = cache[dir], Date().timeIntervalSince(at) < ttl { lock.unlock(); return info }
        lock.unlock()
        var info = Self.detect(dir: dir, command: command)
        if let git = GitCollector.status(dir) { info.gitBranch = git.branch; info.gitDirty = git.dirty }
        lock.lock(); cache[dir] = (info, Date()); lock.unlock()
        return info
    }

    static func detect(dir: String, command: String?) -> ProjectInfo {
        var info = ProjectInfo()
        let fm = FileManager.default
        let url = URL(fileURLWithPath: dir)
        let cmd = (command ?? "").lowercased()

        if let pkg = try? Data(contentsOf: url.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: pkg) as? [String: Any] {
            info.name = json["name"] as? String
            let deps = ((json["dependencies"] as? [String: Any]) ?? [:]).merging((json["devDependencies"] as? [String: Any]) ?? [:]) { a, _ in a }
            if deps["next"] != nil { info.framework = "Next.js" }
            else if deps["nuxt"] != nil { info.framework = "Nuxt" }
            else if deps["@remix-run/react"] != nil { info.framework = "Remix" }
            else if deps["astro"] != nil { info.framework = "Astro" }
            else if deps["@sveltejs/kit"] != nil { info.framework = "SvelteKit" }
            else if deps["@angular/core"] != nil { info.framework = "Angular" }
            else if deps["vite"] != nil { info.framework = "Vite" }
            else if deps["@nestjs/core"] != nil { info.framework = "NestJS" }
            else if deps["express"] != nil { info.framework = "Express" }
            else if deps["fastify"] != nil { info.framework = "Fastify" }
            else if deps["react-native"] != nil || deps["expo"] != nil { info.framework = "Expo" }
            if let nvm = try? String(contentsOf: url.appendingPathComponent(".nvmrc"), encoding: .utf8) { info.runtime = "node \(nvm.trimmingCharacters(in: .whitespacesAndNewlines))" }
        }
        if fm.fileExists(atPath: dir + "/pyproject.toml") || fm.fileExists(atPath: dir + "/manage.py") || fm.fileExists(atPath: dir + "/requirements.txt") {
            if info.name == nil, let toml = try? String(contentsOf: url.appendingPathComponent("pyproject.toml"), encoding: .utf8),
               let m = toml.range(of: #"(?m)^name\s*=\s*"([^"]+)""#, options: .regularExpression) {
                let line = String(toml[m]); info.name = line.split(separator: "\"").dropFirst().first.map(String.init)
            }
            if fm.fileExists(atPath: dir + "/manage.py") { info.framework = "Django" }
            else if cmd.contains("uvicorn") || cmd.contains("fastapi") { info.framework = "FastAPI" }
            else if cmd.contains("flask") { info.framework = "Flask" }
            else if cmd.contains("streamlit") { info.framework = "Streamlit" }
            else if info.framework == nil { info.framework = "Python" }
            if let pv = try? String(contentsOf: url.appendingPathComponent(".python-version"), encoding: .utf8) { info.runtime = "python \(pv.trimmingCharacters(in: .whitespacesAndNewlines))" }
        }
        if fm.fileExists(atPath: dir + "/Cargo.toml") { info.framework = info.framework ?? "Rust" }
        if fm.fileExists(atPath: dir + "/go.mod") { info.framework = info.framework ?? "Go" }
        if fm.fileExists(atPath: dir + "/Gemfile") { info.framework = info.framework ?? (fm.fileExists(atPath: dir + "/config/routes.rb") ? "Rails" : "Ruby") }
        if fm.fileExists(atPath: dir + "/composer.json") { info.framework = info.framework ?? (fm.fileExists(atPath: dir + "/artisan") ? "Laravel" : "PHP") }
        if fm.fileExists(atPath: dir + "/Package.swift") { info.framework = info.framework ?? "SwiftPM" }
        if info.name == nil, dir != "/", dir != NSHomeDirectory() { info.name = url.lastPathComponent }
        return info
    }
}

public enum GitCollector {
    public struct Status: Sendable { public let branch: String; public let dirty: Int; public let ahead: Int; public let behind: Int }

    public static func status(_ dir: String) -> Status? {
        guard FileManager.default.fileExists(atPath: dir + "/.git") || isInsideRepo(dir) else { return nil }
        guard let r = try? Shell.run("git", ["-C", dir, "status", "--porcelain=v1", "--branch"], timeout: 4), r.ok else { return nil }
        let lines = r.stdout.split(separator: "\n")
        guard let head = lines.first, head.hasPrefix("## ") else { return nil }
        var branch = String(head.dropFirst(3))
        var ahead = 0, behind = 0
        if let sp = branch.firstIndex(of: " ") {
            let track = branch[sp...]
            if let m = track.range(of: #"ahead (\d+)"#, options: .regularExpression) { ahead = Int(track[m].split(separator: " ")[1]) ?? 0 }
            if let m = track.range(of: #"behind (\d+)"#, options: .regularExpression) { behind = Int(track[m].split(separator: " ")[1]) ?? 0 }
            branch = String(branch[..<sp])
        }
        if let dots = branch.range(of: "...") { branch = String(branch[..<dots.lowerBound]) }
        return Status(branch: branch, dirty: lines.count - 1, ahead: ahead, behind: behind)
    }

    static func isInsideRepo(_ dir: String) -> Bool {
        var url = URL(fileURLWithPath: dir)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return false
    }
}
