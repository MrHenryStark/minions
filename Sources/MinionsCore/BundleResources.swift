import Foundation

/// Locates a resource SwiftPM bundled with a target, without using the
/// synthesized `Bundle.module` accessor.
///
/// That generated accessor assumes a resource bundle sits directly inside
/// `Bundle.main`'s own root — true for a bare command-line binary (where the
/// bundle lands next to the executable in `.build/`), but wrong for a proper
/// macOS `.app`, where resources live under `Contents/Resources/`. Its only
/// fallback is an *absolute path on the machine that compiled the binary* —
/// baked in at build time — which cannot exist on any other machine. A
/// release built by CI and downloaded by a user therefore has no working
/// fallback at all, and `Bundle.module` crashes the process with an
/// unconditional `fatalError`, which no amount of `guard`/`try?` in calling
/// code can catch.
///
/// This instead looks under the *running* app's own `Contents/Resources/`,
/// which is where `scripts/bundle.sh` copies every SwiftPM resource bundle,
/// and returns `nil` on failure like any normal lookup — callers already
/// handle a missing resource gracefully (an unpriced model shows `?`, a
/// missing menu bar mark falls back to a system symbol).
public enum AppResources {
    /// - Parameters:
    ///   - resourceBundleName: the `.bundle` folder SwiftPM generated for a
    ///     target, e.g. `"Minions_MinionsCore"` (package name + target name).
    ///   - file: the resource's filename inside that bundle.
    public static func url(inResourceBundle resourceBundleName: String, file: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resources.appendingPathComponent("\(resourceBundleName).bundle").appendingPathComponent(file),
            resources.appendingPathComponent(file), // flat fallback, if placement ever changes
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
