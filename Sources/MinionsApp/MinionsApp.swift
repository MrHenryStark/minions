import SwiftUI
import MinionsCore


struct MinionsApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
                .frame(width: 380)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Window("Minions", id: "dashboard") {
            DashboardView().environmentObject(store)
        }
        .defaultSize(width: 960, height: 640)

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var store: AppStore

    /// The bundled mark, loaded as a template image so AppKit tints it to
    /// match the menu bar's light/dark appearance and selected state.
    ///
    /// Loaded via `AppResources`, not `Bundle.module` — SwiftPM's synthesized
    /// accessor looks in the wrong place inside a macOS `.app` and falls back
    /// to a path that only exists on the machine that built the binary, so it
    /// crashes every CI-built release on launch. See `AppResources`'s doc
    /// comment. The @2x file is loaded directly and its size halved to its
    /// logical point size, which AppKit then renders sharply on Retina
    /// displays (effectively every Mac this app targets).
    static let logo: NSImage? = {
        guard let url = AppResources.url(inResourceBundle: "Minions_MinionsApp", file: "MenuBarIcon@2x.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: img.size.width / 2, height: img.size.height / 2)
        img.isTemplate = true
        return img
    }()

    var body: some View {
        HStack(spacing: 4) {
            if let logo = Self.logo {
                Image(nsImage: logo)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
            if store.overBudget {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if !store.portConflicts.isEmpty {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.yellow)
            }
            if !store.menuBarTitle.isEmpty { Text(store.menuBarTitle).monospacedDigit() }
        }
    }
}
