import Foundation

/// Every external command the app runs goes through here so timeouts,
/// environment and error handling are uniform. Never call from the main thread.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var ok: Bool { status == 0 }
    }

    public enum ShellError: Error, CustomStringConvertible {
        case notFound(String)
        case timeout(String)
        public var description: String {
            switch self {
            case .notFound(let c): return "command not found: \(c)"
            case .timeout(let c): return "command timed out: \(c)"
            }
        }
    }

    /// Search path used to resolve bare command names. Docker Desktop and
    /// Homebrew live outside the default launchd PATH for GUI apps.
    public static let searchPath = [
        "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        "\(NSHomeDirectory())/.docker/bin",
    ]

    public static func resolve(_ command: String) -> String? {
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        for dir in searchPath {
            let p = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    public static func run(_ command: String, _ args: [String] = [], timeout: TimeInterval = 10, input: String? = nil) throws -> Result {
        guard let exe = resolve(command) else { throw ShellError.notFound(command) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["LANG"] = "en_US.UTF-8"
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        if let input {
            let inPipe = Pipe()
            proc.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        } else {
            proc.standardInput = FileHandle.nullDevice
        }
        try proc.run()

        // Drain pipes concurrently so a chatty command cannot deadlock on a full buffer.
        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            throw ShellError.timeout(command)
        }
        proc.waitUntilExit()
        return Result(
            status: proc.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
