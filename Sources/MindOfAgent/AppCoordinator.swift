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
/// The class itself is `@MainActor` so SwiftUI callers can invoke
/// `pause()` / `resume()` directly without isolation hops.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var snapshot: NodeRegistry.Snapshot
    @Published private(set) var startupError: String?
    @Published private(set) var paused: Bool = false
    @Published private(set) var thunderboltBridge: NetworkInterface?

    private let registry: NodeRegistry
    private let discovery: Discovery
    private let heartbeat: TelemetryHeartbeat
    private var thunderboltTimer: Timer?

    init() {
        // Snapshot the host's hardware profile once at launch. The values
        // feed Bonjour TXT records so peers see chip + memory + model in
        // their menu without needing an HTTP probe back to us.
        let profile = HardwareProfiler.getProfile()
        let registry = NodeRegistry()
        let config = Discovery.Config(
            hostname: profile.hostname,
            txtRecord: profile.txtRecord
        )
        self.registry = registry
        self.discovery = Discovery(config: config, registry: registry)
        self.snapshot = registry.snapshot()

        // Heartbeat publishes live cpu_pct / mem_used_mb / mem_pressure
        // into our Bonjour TXT records every 10s. Peers reading our
        // browse callback see fresh telemetry without an HTTP round-trip.
        // Controller-POST sink lands in #13.
        let sink = BonjourTXTSink(discovery: discovery)
        self.heartbeat = TelemetryHeartbeat(sinks: [sink], interval: .seconds(10))

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

        // Kick off the telemetry loop. .start() on an actor needs Task —
        // the loop is self-contained and we don't need to await it here.
        Task { [heartbeat] in await heartbeat.start() }

        // Poll the Thunderbolt-bridge state every 5s so the menu reflects
        // cables being plugged/unplugged without a manual refresh. SC
        // doesn't surface a Combine-friendly observer for interface state,
        // and a 5s tick keeps overhead trivial.
        refreshThunderbolt()
        thunderboltTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            // Inner `[weak self]` is required for Swift 5.9 / Xcode 15.4
            // region analysis: without it, the Task closure is flagged as
            // capturing `self` from the outer closure's optional, which
            // crosses isolation domains. The double weak-capture has no
            // runtime cost — both unwrap the same reference.
            Task { @MainActor [weak self] in
                self?.refreshThunderbolt()
            }
        }
    }

    deinit {
        // AppCoordinator is process-lifetime today, but a deinit-paired
        // stop() keeps the NWListener + NWBrowser from leaking if the
        // coordinator is ever re-created (previews, future tests). The
        // heartbeat's Task captures self weakly, so a coordinator dropped
        // mid-tick will see the next loop iteration find a nil self and
        // exit cleanly — we still ask politely with stop() to avoid the
        // stragglers.
        thunderboltTimer?.invalidate()
        let hb = heartbeat
        Task { await hb.stop() }
        discovery.stop()
    }

    // MARK: - Thunderbolt

    /// Refresh the cached Thunderbolt bridge state. Public so callers can
    /// trigger an immediate update (e.g. after a user reports plugging
    /// in a cable).
    func refreshThunderbolt() {
        thunderboltBridge = NetworkManager.thunderboltBridge()
    }

    // MARK: - Pause / resume

    /// Stop advertising and browsing. The local registry freezes at its
    /// last-known state — peers will no longer see this node and this node
    /// will stop seeing departures, but already-known peers stay in the
    /// menu until a resume drives a fresh browse cycle.
    func pause() {
        guard !paused else { return }
        discovery.stop()
        let hb = heartbeat
        Task { await hb.stop() }
        paused = true
    }

    /// Re-advertise + re-browse. The registry keeps its last snapshot; once
    /// the new browser starts firing, stale peers are pruned via
    /// `Discovery.handle(results:)`'s diff. Briefly (≤ ~2 s) the menu may
    /// show peers that have left the network — they vacate on the first
    /// browse update.
    func resume() {
        guard paused else { return }
        do {
            try discovery.start()
            let hb = heartbeat
            Task { await hb.start() }
            paused = false
            startupError = nil
        } catch {
            startupError = "Resume failed: \(error.localizedDescription)"
        }
    }

    func togglePause() {
        // Refuse to toggle while in a startup-error state. The pause button
        // is also disabled in the view, but this guard makes the contract
        // explicit at the model layer too.
        guard startupError == nil else { return }
        paused ? resume() : pause()
    }
}
