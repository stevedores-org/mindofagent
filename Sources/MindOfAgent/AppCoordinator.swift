import Foundation
import AppKit
import MindOfAgentCore

/// Owns the long-lived `Discovery` + `NodeRegistry` and publishes snapshots
/// to SwiftUI views via `@Published`. One instance per app launch.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var snapshot: NodeRegistry.Snapshot
    @Published private(set) var startupError: String?

    private let registry: NodeRegistry
    private let discovery: Discovery

    init() {
        let hostname = Host.current().localizedName ?? "mac-node"
        let registry = NodeRegistry()
        let config = Discovery.Config(hostname: hostname)
        self.registry = registry
        self.discovery = Discovery(config: config, registry: registry)
        self.snapshot = registry.snapshot()

        registry.subscribe { [weak self] snap in
            Task { @MainActor in
                self?.snapshot = snap
            }
        }

        do {
            try discovery.start()
        } catch {
            self.startupError = "Discovery failed: \(error.localizedDescription)"
        }
    }
}
