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

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = AppState.currentSchemaVersion,
        clusterId: UUID = UUID(),
        preferredPeers: [String] = [],
        paused: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.clusterId = clusterId
        self.preferredPeers = preferredPeers
        self.paused = paused
    }
}
