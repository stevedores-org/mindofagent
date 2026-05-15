import XCTest
@testable import MindOfAgentCore

final class StateStoreTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mindofagent-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeStore(named name: String = "state.json") -> StateStore {
        StateStore(fileURL: tempDir.appendingPathComponent(name))
    }

    // MARK: - load

    func testLoadCreatesDefaultsWhenFileMissing() async throws {
        let store = makeStore()
        let state = await store.load()

        XCTAssertEqual(state.schemaVersion, AppState.currentSchemaVersion)
        XCTAssertEqual(state.preferredPeers, [])
        XCTAssertFalse(state.paused)

        // Defaults must be written through so the next launch can read them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: - round trip

    func testSaveThenLoadRoundTripsExactValues() async throws {
        let store = makeStore()
        let written = AppState(
            schemaVersion: AppState.currentSchemaVersion,
            clusterId: UUID(),
            preferredPeers: ["alpha", "bravo"],
            paused: true
        )
        try await store.save(written)

        // Fresh store so the cached value can't fake a pass.
        let fresh = makeStore()
        let read = await fresh.load()
        XCTAssertEqual(read, written)
    }

    // MARK: - corruption recovery

    func testCorruptFileIsReplacedWithDefaults() async throws {
        let store = makeStore()
        try "{ this is not valid json".data(using: .utf8)!
            .write(to: store.fileURL, options: [.atomic])

        let state = await store.load()
        XCTAssertEqual(state.preferredPeers, [])
        XCTAssertFalse(state.paused)
        XCTAssertEqual(state.schemaVersion, AppState.currentSchemaVersion)

        // File must be valid JSON after the recovery write.
        let recovered = try Data(contentsOf: store.fileURL)
        XCTAssertNoThrow(try JSONDecoder().decode(AppState.self, from: recovered))
    }

    // MARK: - update transform

    func testUpdateAppliesTransformAndPersists() async throws {
        let store = makeStore()
        let updated = try await store.update { $0.paused = true; $0.preferredPeers = ["alpha"] }

        XCTAssertTrue(updated.paused)
        XCTAssertEqual(updated.preferredPeers, ["alpha"])

        let onDisk = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: store.fileURL))
        XCTAssertEqual(onDisk, updated)
    }

    // MARK: - concurrent writes

    func testConcurrentUpdatesAreSerialisedByActor() async throws {
        let store = makeStore()
        // 64 concurrent appends; the actor must serialise so the final
        // preferredPeers list contains all 64 entries.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask {
                    _ = try? await store.update { state in
                        state.preferredPeers.append("peer-\(i)")
                    }
                }
            }
        }

        let final = await store.load()
        XCTAssertEqual(final.preferredPeers.count, 64)
        XCTAssertEqual(Set(final.preferredPeers).count, 64, "all writes preserved (no last-writer-wins)")
    }

    // MARK: - defaultURL

    func testDefaultURLEndsInExpectedPath() {
        let url = StateStore.defaultURL()
        XCTAssertTrue(url.path.hasSuffix("/MindOfAgent/state.json"), url.path)
    }
}
