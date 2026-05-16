import Foundation
import AppKit
import MindOfAgentCore

/// Owns the long-lived `Discovery` + `NodeRegistry` and publishes snapshots
/// to SwiftUI views via `@Published`. One instance per app launch.
///
/// Snapshot updates are delivered on `DispatchQueue.main` so they preserve
/// FIFO order — `Task { @MainActor in … }` does not guarantee execution
/// order relative to spawn order, and a burst of registry mutations could
/// otherwise produce momentary UI flicker as snapshots arrive out-of-order.
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
            // DispatchQueue.main.async preserves FIFO from a single producer
            // (the registry's notify queue). The published value reflects
            // registry mutations in order, no late snapshots overwriting
            // newer ones.
            DispatchQueue.main.async {
                self?.snapshot = snap
            }
        }

        do {
            try discovery.start()
        } catch {
            self.startupError = "Discovery failed: \(error.localizedDescription)"
        }
    }

    deinit {
        // AppCoordinator is process-lifetime today, but a deinit-paired
        // stop() keeps the NWListener + NWBrowser from leaking if the
        // coordinator is ever re-created (previews, future tests).
        discovery.stop()
    }
}
