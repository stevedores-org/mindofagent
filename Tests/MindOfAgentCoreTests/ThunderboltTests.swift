import XCTest
@testable import MindOfAgentCore

final class ThunderboltTests: XCTestCase {

    /// `isBridgeInterface` for an obviously-non-bridge name must return
    /// `false`. Doubles as a smoke test that the SC enumeration path
    /// doesn't crash.
    func testIsBridgeInterfaceFalseForLoopback() {
        XCTAssertFalse(NetworkManager.isBridgeInterface(named: "lo0"))
    }

    func testIsBridgeInterfaceFalseForUnknownName() {
        XCTAssertFalse(NetworkManager.isBridgeInterface(named: "no-such-iface-12345"))
    }

    /// On a Mac with a Thunderbolt cable plugged in, `bridge0` should be
    /// classified as `.thunderboltBridge`. We can't assert presence
    /// (depends on the test machine), but we *can* assert the
    /// contract: when `thunderboltBridge()` returns a value, it's the
    /// canonical Thunderbolt bridge.
    func testThunderboltBridgeIfPresentHasMatchingKindAndLinkLocalIPv4() {
        guard let tb = NetworkManager.thunderboltBridge() else {
            // No Thunderbolt cable connected — that's fine, just skip.
            return
        }
        XCTAssertEqual(tb.kind, .thunderboltBridge)
        XCTAssertTrue(tb.ipv4.contains(where: { $0.hasPrefix("169.254.") }),
                      "Thunderbolt bridge must carry a 169.254/16 IPv4")
        XCTAssertTrue(tb.name.hasPrefix("bridge"),
                      "Thunderbolt bridge interface name must start with 'bridge'")
    }
}
