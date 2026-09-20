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
    static let logo: NSImage? = {
        let img = Bundle.module.image(forResource: "MenuBarIcon")
        img?.isTemplate = true
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
