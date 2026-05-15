import Foundation

public struct Node: Identifiable, Hashable, Sendable {
    public let id: String
    public let hostname: String
    public let host: String
    public let port: Int
    public let txtRecord: [String: String]
    public var firstSeen: Date
    public var lastSeen: Date

    public init(
        id: String,
        hostname: String,
        host: String,
        port: Int,
        txtRecord: [String: String] = [:],
        firstSeen: Date = Date(),
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.hostname = hostname
        self.host = host
        self.port = port
        self.txtRecord = txtRecord
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public extension Node {
    var displayName: String {
        if let chip = txtRecord["chip"] { return "\(hostname) (\(chip))" }
        return hostname
    }

    var memoryGB: Int? {
        txtRecord["mem_gb"].flatMap(Int.init)
    }
}
