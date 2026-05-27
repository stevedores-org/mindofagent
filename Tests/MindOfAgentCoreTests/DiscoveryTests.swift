import XCTest
import Network
@testable import MindOfAgentCore

final class DiscoveryTests: XCTestCase {

    // Regression for #43: a hardcoded default port caused a second
    // instance on the same host to silently fail to bind. The fix is
    // to ask the kernel for any free port by default.
    func testTwoInstancesOnSameHostBothStart() throws {
        let registryA = NodeRegistry()
        let registryB = NodeRegistry()
        let discoveryA = Discovery(
            config: Discovery.Config(hostname: "discovery-test-a"),
            registry: registryA
        )
        let discoveryB = Discovery(
            config: Discovery.Config(hostname: "discovery-test-b"),
            registry: registryB
        )
        defer {
            discoveryA.stop()
            discoveryB.stop()
        }

        XCTAssertNoThrow(try discoveryA.start())
        XCTAssertNoThrow(try discoveryB.start())
    }
}
