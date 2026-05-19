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

    /// Regression for the PR #18 review: upsert previously dropped every
    /// field except `lastSeen` on update. The registry must take every
    /// field from the new value except `firstSeen` so that a peer's TXT
    /// record / port / host changes propagate.
    func testUpsertReplacesAllFieldsExceptFirstSeen() {
        let registry = NodeRegistry()
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let later = firstSeen.addingTimeInterval(60)

        registry.upsert(Node(
            id: "a",
            hostname: "alpha-old",
            host: "10.0.0.1",
            port: 11_111,
            txtRecord: ["chip": "M3"],
            firstSeen: firstSeen,
            lastSeen: firstSeen
        ))

        registry.upsert(Node(
            id: "a",
            hostname: "alpha-new",
            host: "10.0.0.2",
            port: 22_222,
            txtRecord: ["chip": "M4", "mem_gb": "64"],
            firstSeen: later, // should be ignored — firstSeen is sticky
            lastSeen: later
        ))

        let stored = registry.snapshot().nodes.first!
        XCTAssertEqual(stored.firstSeen, firstSeen, "firstSeen is sticky from first-observed")
        XCTAssertEqual(stored.lastSeen, later)
        XCTAssertEqual(stored.hostname, "alpha-new")
        XCTAssertEqual(stored.host, "10.0.0.2")
        XCTAssertEqual(stored.port, 22_222)
        XCTAssertEqual(stored.txtRecord["chip"], "M4")
        XCTAssertEqual(stored.txtRecord["mem_gb"], "64")
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

    /// Regression for the PR #19 review (#28 follow-up): a remove of an
    /// unknown id used to fan out observer notifications even though
    /// nothing changed. At scale this caused UI churn — the menu would
    /// redraw on every Discovery.handle stale-cleanup pass even when
    /// no peers had actually left.
    func testRemoveOfUnknownIdDoesNotFireObservers() {
        let registry = NodeRegistry()
        registry.upsert(Self.makeNode(id: "a", hostname: "alpha"))

        // Synchronise on the initial-subscribe fire, then count observer
        // fires until the test deadline expires.
        let initial = expectation(description: "initial fire")
        let lock = NSLock()
        var count = 0
        registry.subscribe { _ in
            lock.lock(); defer { lock.unlock() }
            count += 1
            if count == 1 { initial.fulfill() }
        }
        wait(for: [initial], timeout: 2)

        registry.remove(id: "does-not-exist")

        // Wait long enough for any spurious notification to have landed
        // on the notify queue.
        let waiter = expectation(description: "settle")
        registry.subscribe { _ in waiter.fulfill() }
        wait(for: [waiter], timeout: 2)

        // The first observer's `count` increments on every fire to its
        // handler. The second observer doesn't touch `count`. So `count`
        // should stay at 1 (the first observer's initial fire) — if the
        // no-op remove had fanned out, the first observer would have
        // fired again and we'd see 2.
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(count, 1, "no-op remove must not fire observers (would be ≥2 if it did)")
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

    func testSubscribeDeliversInitialSnapshot() {
        let registry = NodeRegistry()
        registry.upsert(Self.makeNode(id: "a", hostname: "alpha"))

        let received = expectation(description: "initial snapshot delivered")
        let lock = NSLock()
        var observed: [[String]] = []
        registry.subscribe { snap in
            lock.lock(); defer { lock.unlock() }
            observed.append(snap.nodes.map(\.id))
            if observed.count == 1 { received.fulfill() }
        }

        wait(for: [received], timeout: 2)
        XCTAssertEqual(observed.first, ["a"], "subscribe must deliver the current snapshot")
    }

    func testSubscribeFiresOnEachMutation() {
        let registry = NodeRegistry()
        let received = expectation(description: "all four snapshots delivered")
        received.expectedFulfillmentCount = 4
        let lock = NSLock()
        var observed: [[String]] = []
        registry.subscribe { snap in
            lock.lock(); defer { lock.unlock() }
            observed.append(snap.nodes.map(\.id))
            received.fulfill()
        }

        // Initial empty snapshot from subscribe + one fire per mutation = 4 total.
        registry.upsert(Self.makeNode(id: "a", hostname: "alpha"))
        registry.upsert(Self.makeNode(id: "b", hostname: "bravo"))
        registry.remove(id: "a")

        wait(for: [received], timeout: 2)
        XCTAssertEqual(observed[0], [])
        XCTAssertEqual(observed[1], ["a"])
        XCTAssertEqual(observed[2], ["a", "b"])
        XCTAssertEqual(observed[3], ["b"])
    }

    /// Regression for the PR #18 review: observers used to be invoked
    /// inside `queue.sync`, so an observer calling back into the registry
    /// would deadlock on the serial queue. The test calls `snapshot()` from
    /// inside an observer; previously this would hang forever.
    func testObserverMayCallBackIntoRegistryWithoutDeadlock() {
        let registry = NodeRegistry()
        let observed = expectation(description: "observer received snapshot")
        observed.expectedFulfillmentCount = 2 // initial empty + 1 mutation

        registry.subscribe { _ in
            // Re-entrant read — must not deadlock.
            _ = registry.snapshot()
            observed.fulfill()
        }

        registry.upsert(Self.makeNode(id: "a", hostname: "alpha"))

        wait(for: [observed], timeout: 2)
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

    /// Concurrency test with a live observer subscribed — verifies the
    /// notify-outside-lock semantics hold under contention. PR #19
    /// review (#28 follow-up): the bare concurrency test didn't exercise
    /// observer fan-out, which is where lock contention would actually
    /// bite if the implementation regressed.
    func testConcurrentUpsertConvergesWithObserverSubscribed() {
        let registry = NodeRegistry()
        let observerFired = expectation(description: "observer received at least one fire")
        let lock = NSLock()
        var fireCount = 0
        registry.subscribe { _ in
            lock.lock(); defer { lock.unlock() }
            fireCount += 1
            if fireCount == 1 { observerFired.fulfill() }
        }

        let count = 128
        let group = DispatchGroup()
        let concurrent = DispatchQueue(label: "test.concurrent.obs", attributes: .concurrent)
        for i in 0..<count {
            concurrent.async(group: group) {
                registry.upsert(Self.makeNode(id: "n-\(i)", hostname: "host-\(i)"))
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        wait(for: [observerFired], timeout: 5)
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
