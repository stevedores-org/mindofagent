import SwiftUI
import AppKit
import MindOfAgentCore

struct MindOfAgentApp: App {
    @StateObject private var coordinator: AppCoordinator

    init() {
        // SwiftPM-built executables show a Dock icon by default. .accessory
        // removes both the Dock icon and the app's main menu so we are
        // purely a menu-bar app. Equivalent to LSUIElement=YES in Info.plist,
        // but doesn't require packaging the binary into a .app bundle.
        NSApplication.shared.setActivationPolicy(.accessory)

        // Pull the controller URL from state.json synchronously so the
        // coordinator's first Task can fire its initial registration
        // POST. nil ⇒ mesh-only mode (zero outbound traffic) which is
        // the v0 default.
        let configuredURL = AppState.loadFromDefaultLocation().controllerURL
        _coordinator = StateObject(wrappedValue: AppCoordinator(controllerURL: configuredURL))
    }

    var body: some Scene {
        MenuBarExtra("MindOfAgent", systemImage: coordinator.paused ? "network.slash" : "network") {
            MenuView(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}
