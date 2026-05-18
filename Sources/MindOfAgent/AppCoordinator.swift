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
    @Published private(set) var lastRegistrationStatus: String?
    @Published private(set) var lastRegistrationAt: Date?

    private let registry: NodeRegistry
    private let discovery: Discovery
    private let profile: HardwareProfile
    private let registrationService: RegistrationService?
    private var thunderboltTimer: Timer?
    private var registrationStatusTimer: Timer?

    init(controllerURL: URL? = nil) {
        // Snapshot the host's hardware profile once at launch. The values
        // feed Bonjour TXT records so peers see chip + memory + model in
        // their menu without needing an HTTP probe back to us.
        let profile = HardwareProfiler.getProfile()
        self.profile = profile
        let registry = NodeRegistry()
        let config = Discovery.Config(
            hostname: profile.hostname,
            txtRecord: profile.txtRecord
        )
        self.registry = registry
        self.discovery = Discovery(config: config, registry: registry)
        self.snapshot = registry.snapshot()

        // Controller registration is opt-in. nil ⇒ mesh-only mode, zero
        // outbound traffic. URL configured ⇒ kick off a POST after
        // discovery starts (and on every Thunderbolt link-state change).
        if let url = controllerURL {
            self.registrationService = RegistrationService(controllerURL: url)
        } else {
            self.registrationService = nil
        }

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

        // Initial registration POST if the controller is configured.
        // The retry chain handles transient 5xx / timeouts internally,
        // so we just fire and forget here.
        registerNow()

        // Poll registrationService for status changes so the menu can
        // show "last registered HH:MM:SS" without us plumbing observers
        // across the actor boundary. 2s is fine — registrations happen
        // on minute-plus cadence.
        registrationStatusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshRegistrationStatus()
            }
        }
    }

    deinit {
        // AppCoordinator is process-lifetime today, but a deinit-paired
        // stop() keeps the NWListener + NWBrowser from leaking if the
        // coordinator is ever re-created (previews, future tests).
        thunderboltTimer?.invalidate()
        registrationStatusTimer?.invalidate()
        if let svc = registrationService {
            Task { await svc.cancel() }
        }
        discovery.stop()
    }

    // MARK: - Thunderbolt

    /// Refresh the cached Thunderbolt bridge state. Public so callers can
    /// trigger an immediate update (e.g. after a user reports plugging
    /// in a cable). Fires a fresh registration POST if the bridge
    /// changed (per #13: re-register on every link-state change).
    func refreshThunderbolt() {
        let previous = thunderboltBridge
        let current = NetworkManager.thunderboltBridge()
        thunderboltBridge = current
        // Compare by name + first IPv4 — value-equality on
        // NetworkInterface would also trigger on irrelevant txtRecord
        // changes from other interfaces.
        let prevKey = previous.map { "\($0.name)|\($0.ipv4.first ?? "")" }
        let curKey = current.map { "\($0.name)|\($0.ipv4.first ?? "")" }
        if prevKey != curKey {
            registerNow()
        }
    }

    // MARK: - Registration

    /// Fire a registration POST with the current snapshot of
    /// HardwareProfile + Thunderbolt info. No-op when no controller is
    /// configured.
    func registerNow() {
        guard let svc = registrationService else { return }
        let payload = RegistrationPayload(
            hardware: profile,
            thunderbolt: thunderboltBridge
        )
        Task { await svc.register(payload: payload) }
    }

    private func refreshRegistrationStatus() async {
        guard let svc = registrationService else { return }
        let success = await svc.lastSuccess
        let error = await svc.lastError
        lastRegistrationAt = success
        lastRegistrationStatus = error
    }

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

    /// Re-advertise + re-browse. The registry keeps its last snapshot; once
    /// the new browser starts firing, stale peers are pruned via
    /// `Discovery.handle(results:)`'s diff. Briefly (≤ ~2 s) the menu may
    /// show peers that have left the network — they vacate on the first
    /// browse update.
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
        // Refuse to toggle while in a startup-error state. The pause button
        // is also disabled in the view, but this guard makes the contract
        // explicit at the model layer too.
        guard startupError == nil else { return }
        paused ? resume() : pause()
    }
}
