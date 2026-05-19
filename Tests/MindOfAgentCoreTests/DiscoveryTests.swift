import XCTest
import Network
@testable import MindOfAgentCore

/// Regression coverage for #43: a hardcoded default port caused a second
/// instance on the same host to silently fail to bind. The fix is to ask
/// the OS for any free port by default and publish the chosen port in TXT.
final class DiscoveryTests: XCTestCase {

    func testDefaultConfigPortIsNilForOSAssignedPort() {
        let config = Discovery.Config(hostname: "test-host")
        XCTAssertNil(
            config.port,
            "Default port must be nil so the OS picks any free port (#43)."
        )
    }

    /// Regression for #43: two instances on the same host both bind
    /// successfully when using the default (`.any`) port.
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
