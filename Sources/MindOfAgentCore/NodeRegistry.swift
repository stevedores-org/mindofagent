import Foundation

/// In-memory registry of discovered nodes. Thread-safe via a serial queue.
public final class NodeRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.stevedores.mindofagent.registry")
    private var storage: [String: Node] = [:]
    private var observers: [(Snapshot) -> Void] = []

    public struct Snapshot: Sendable {
        public let nodes: [Node]
        public let updatedAt: Date
    }

    public init() {}

    public func upsert(_ node: Node) {
        queue.sync {
            if var existing = storage[node.id] {
                existing.lastSeen = node.lastSeen
                storage[node.id] = existing
            } else {
                storage[node.id] = node
            }
            notifyLocked()
        }
    }

    public func remove(id: String) {
        queue.sync {
            storage.removeValue(forKey: id)
            notifyLocked()
        }
    }

    public func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(nodes: Array(storage.values).sorted { $0.hostname < $1.hostname }, updatedAt: Date())
        }
    }

    public func subscribe(_ handler: @escaping (Snapshot) -> Void) {
        queue.sync {
            observers.append(handler)
            handler(Snapshot(nodes: Array(storage.values).sorted { $0.hostname < $1.hostname }, updatedAt: Date()))
        }
    }

    private func notifyLocked() {
        let snap = Snapshot(nodes: Array(storage.values).sorted { $0.hostname < $1.hostname }, updatedAt: Date())
        for observer in observers { observer(snap) }
    }
}
