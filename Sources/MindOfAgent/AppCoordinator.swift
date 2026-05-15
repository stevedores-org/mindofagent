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
    @Published private(set) var paused: Bool = false

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

<<<<<<< HEAD
    deinit {
        // AppCoordinator is process-lifetime today, but a deinit-paired
        // stop() keeps the NWListener + NWBrowser from leaking if the
        // coordinator is ever re-created (previews, future tests).
        discovery.stop()
=======
    // MARK: - Pause / resume

    /// Stop advertising and browsing. The local registry freezes at its
    /// last-known state — peers will no longer see this node and this node
    /// will stop seeing departures, but already-known peers stay in the
    /// menu until a resume drives a fresh browse cycle.
    func pause() {
        guard !paused else { return }
        discovery.stop()
        paused = true
    }

    /// Re-advertise + re-browse. Clears the existing snapshot so the
    /// post-resume view rebuilds purely from fresh browse results.
    func resume() {
        guard paused else { return }
        do {
            try discovery.start()
            paused = false
            startupError = nil
        } catch {
            startupError = "Resume failed: \(error.localizedDescription)"
        }
    }

    func togglePause() {
        paused ? resume() : pause()
>>>>>>> 9e95079 (feat(coordinator): pause()/resume()/togglePause() driving Discovery start/stop)
    }
}
