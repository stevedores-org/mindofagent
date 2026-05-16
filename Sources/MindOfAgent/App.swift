import SwiftUI
import AppKit
import MindOfAgentCore

@main
struct MindOfAgentApp: App {
    @StateObject private var coordinator = AppCoordinator()

    init() {
        // SwiftPM-built executables show a Dock icon by default. .accessory
        // removes both the Dock icon and the app's main menu so we are
        // purely a menu-bar app. Equivalent to LSUIElement=YES in Info.plist,
        // but doesn't require packaging the binary into a .app bundle.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("MindOfAgent", systemImage: "network") {
            MenuView(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}
