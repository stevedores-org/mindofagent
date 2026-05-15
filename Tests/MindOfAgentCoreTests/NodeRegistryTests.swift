import XCTest
@testable import MindOfAgentCore

final class NodeRegistryTests: XCTestCase {

    // MARK: - upsert

    func testUpsertInsertsNewNode() {
        let registry = NodeRegistry()
        let node = Self.makeNode(id: "a", hostname: "alpha")

        registry.upsert(node)

        let snap = registry.snapshot()
        XCTAssertEqual(snap.nodes.count, 1)
        XCTAssertEqual(snap.nodes.first?.id, "a")
    }

    func testUpsertPreservesFirstSeenAndUpdatesLastSeen() {
        let registry = NodeRegistry()
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let later = firstSeen.addingTimeInterval(60)

        let original = Self.makeNode(id: "a", hostname: "alpha", firstSeen: firstSeen, lastSeen: firstSeen)
        registry.upsert(original)

        // Re-upsert with same id but a later lastSeen. firstSeen on the new
        // value is intentionally different to prove the registry ignored it.
        let updated = Self.makeNode(id: "a", hostname: "alpha", firstSeen: later, lastSeen: later)
        registry.upsert(updated)

        let stored = registry.snapshot().nodes.first!
        XCTAssertEqual(stored.firstSeen, firstSeen, "firstSeen must be preserved across re-upsert")
        XCTAssertEqual(stored.lastSeen, later, "lastSeen must be updated on re-upsert")
    }

    // MARK: - remove

    func testRemoveDeletesById() {
        let registry = NodeRegistry()
        registry.upsert(Self.makeNode(id: "a", hostname: "alpha"))
        registry.upsert(Self.makeNode(id: "b", hostname: "bravo"))

        registry.remove(id: "a")

        let ids = registry.snapshot().nodes.map(\.id)
        XCTAssertEqual(ids, ["b"])
    }

    func testRemoveIsNoopForUnknownId() {
        let registry = NodeRegistry()
        registry.upsert(Self.makeNode(id: "a", hostname: "alpha"))

        registry.remove(id: "does-not-exist")

        XCTAssertEqual(registry.snapshot().nodes.count, 1)
    }

    // MARK: - snapshot ordering

    func testSnapshotSortsByHostname() {
        let registry = NodeRegistry()
        registry.upsert(Self.makeNode(id: "1", hostname: "charlie"))
        registry.upsert(Self.makeNode(id: "2", hostname: "alpha"))
        registry.upsert(Self.makeNode(id: "3", hostname: "bravo"))

        let hostnames = registry.snapshot().nodes.map(\.hostname)
        XCTAssertEqual(hostnames, ["alpha", "bravo", "charlie"])
    }

    // MARK: - subscribe

    func testSubscribeFiresSynchronouslyWithInitialSnapshot() {
        let registry = NodeRegistry()
        registry.upsert(Self.makeNode(id: "a", hostname: "alpha"))

        var observed: [[String]] = []
        registry.subscribe { snap in
            observed.append(snap.nodes.map(\.id))
        }

        XCTAssertEqual(observed.first, ["a"], "subscribe must fire synchronously with current snapshot")
    }

    func testSubscribeFiresOnEachMutation() {
        let registry = NodeRegistry()
        var observed: [[String]] = []
        registry.subscribe { snap in
            observed.append(snap.nodes.map(\.id))
        }

        // Initial empty snapshot from subscribe + one fire per mutation = 4 total.
        registry.upsert(Self.makeNode(id: "a", hostname: "alpha"))
        registry.upsert(Self.makeNode(id: "b", hostname: "bravo"))
        registry.remove(id: "a")

        XCTAssertEqual(observed.count, 4, "expected: initial empty + 3 mutations")
        XCTAssertEqual(observed[0], [])
        XCTAssertEqual(observed[1], ["a"])
        XCTAssertEqual(observed[2], ["a", "b"])
        XCTAssertEqual(observed[3], ["b"])
    }

    // MARK: - concurrency

    func testConcurrentUpsertConverges() {
        let registry = NodeRegistry()
        let count = 256
        let group = DispatchGroup()
        let concurrent = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<count {
            concurrent.async(group: group) {
                registry.upsert(Self.makeNode(id: "n-\(i)", hostname: "host-\(i)"))
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(registry.snapshot().nodes.count, count)
    }

    // MARK: - helpers

    private static func makeNode(
        id: String,
        hostname: String,
        firstSeen: Date = Date(),
        lastSeen: Date = Date()
    ) -> Node {
        Node(
            id: id,
            hostname: hostname,
            host: "fe80::1",
            port: 52480,
            txtRecord: [:],
            firstSeen: firstSeen,
            lastSeen: lastSeen
        )
    }
}
