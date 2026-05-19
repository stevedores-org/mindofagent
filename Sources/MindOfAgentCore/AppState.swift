import Foundation

/// On-disk app state. Stored as JSON at
/// `~/Library/Application Support/MindOfAgent/state.json`.
///
/// `schemaVersion` is reserved for forward-compatible migrations. Bump it
/// whenever a non-additive field change ships and add a decoding shim.
public struct AppState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var clusterId: UUID
    public var preferredPeers: [String]
    public var paused: Bool
    /// Optional opt-in controller URL. When non-nil, `RegistrationService`
    /// POSTs the host's HardwareProfile + Thunderbolt info on launch and
    /// on every Thunderbolt link-state change. When nil, the service is
    /// dormant — zero outbound traffic, mesh-only mode (the v0 default).
    public var controllerURL: URL?

    /// Synchronous best-effort read from the default state.json. Used by
    /// SwiftUI app entry points where the configuration must be known
    /// before `@StateObject` evaluates. Returns defaults on missing or
    /// unparseable file — same behaviour as `StateStore.load()` but
    /// without the actor hop, and without the corrupt-file backup side
    /// effect (the next async `StateStore.load()` performs that).
    public static func loadFromDefaultLocation() -> AppState {
        let url = StateStore.defaultURL()
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(AppState.self, from: data)
        else { return AppState() }
        return state
    }

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = AppState.currentSchemaVersion,
        clusterId: UUID = UUID(),
        preferredPeers: [String] = [],
        paused: Bool = false,
        controllerURL: URL? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.clusterId = clusterId
        self.preferredPeers = preferredPeers
        self.paused = paused
        self.controllerURL = controllerURL
    }
}
