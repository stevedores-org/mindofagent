import Foundation

/// In-memory registry of discovered nodes. Thread-safe via a serial queue.
///
/// Observers are notified *outside* the lock — the `subscribe`/`upsert`/`remove`
/// paths build the snapshot under `queue.sync` and then dispatch the
/// notification on a separate queue so an observer that calls back into the
/// registry can't re-enter and deadlock.
public final class NodeRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.stevedores.mindofagent.registry")
    private let notify = DispatchQueue(label: "io.stevedores.mindofagent.registry.notify")
    private var storage: [String: Node] = [:]
    private var observers: [(Snapshot) -> Void] = []

    public struct Snapshot: Sendable {
        public let nodes: [Node]
        /// Time the snapshot was taken (i.e. when `snapshot()` ran or when
        /// an observer was notified). Not the time of the last mutation.
        public let takenAt: Date
    }

    public init() {}

    /// Insert a new node or replace an existing one with the same id. On
    /// update, every field except `firstSeen` is taken from the new value;
    /// `firstSeen` is preserved from the existing entry so the registry
    /// records when the peer was first observed.
    public func upsert(_ node: Node) {
        let (snap, snapshotObservers) = queue.sync { () -> (Snapshot, [(Snapshot) -> Void]) in
            if let existing = storage[node.id] {
                var merged = node
                merged.firstSeen = existing.firstSeen
                storage[node.id] = merged
            } else {
                storage[node.id] = node
            }
            return (makeSnapshotLocked(), observers)
        }
        dispatchNotify(snap, observers: snapshotObservers)
    }

    /// Remove a node by id. Observers are only notified when an entry
    /// was actually removed — a remove of an unknown id is a true no-op
    /// (no spurious snapshot fan-out at scale).
    public func remove(id: String) {
        let result = queue.sync { () -> (Snapshot, [(Snapshot) -> Void])? in
            guard storage.removeValue(forKey: id) != nil else { return nil }
            return (makeSnapshotLocked(), observers)
        }
        if let (snap, snapshotObservers) = result {
            dispatchNotify(snap, observers: snapshotObservers)
        }
    }

    public func snapshot() -> Snapshot {
        queue.sync { makeSnapshotLocked() }
    }

    /// Register a handler. The handler fires immediately with the current
    /// snapshot (on the notify queue), then again on every subsequent
    /// mutation. Handlers must not assume any particular thread.
    public func subscribe(_ handler: @escaping (Snapshot) -> Void) {
        let snap = queue.sync { () -> Snapshot in
            observers.append(handler)
            return makeSnapshotLocked()
        }
        notify.async { handler(snap) }
    }

    // MARK: - private

    private func makeSnapshotLocked() -> Snapshot {
        Snapshot(
            nodes: Array(storage.values).sorted { $0.hostname < $1.hostname },
            takenAt: Date()
        )
    }

    private func dispatchNotify(_ snap: Snapshot, observers: [(Snapshot) -> Void]) {
        notify.async {
            for observer in observers { observer(snap) }
        }
    }
}
