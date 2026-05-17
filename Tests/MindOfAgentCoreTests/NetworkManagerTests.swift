import XCTest
@testable import MindOfAgentCore

final class NetworkManagerTests: XCTestCase {

    // MARK: - classify

    func testGroupsRowsByInterfaceNameAndPreservesOrder() {
        let rows: [NetworkManager.RawAddress] = [
            // First-seen order: en0, lo0, en1
            .init(name: "en0", family: .link, address: "a4:83:e7:00:00:01", isUp: true),
            .init(name: "en0", family: .ipv4, address: "192.168.1.10", isUp: true),
            .init(name: "lo0", family: .ipv4, address: "127.0.0.1", isUp: true),
            .init(name: "en1", family: .ipv6, address: "fe80::1", isUp: true),
            // A second en0 ipv6 row to prove grouping holds.
            .init(name: "en0", family: .ipv6, address: "fe80::2", isUp: true),
        ]

        let result = NetworkManager.classify(rows: rows)

        XCTAssertEqual(result.map(\.name), ["en0", "lo0", "en1"])

        let en0 = result.first { $0.name == "en0" }!
        XCTAssertEqual(en0.ipv4, ["192.168.1.10"])
        XCTAssertEqual(en0.ipv6, ["fe80::2"])
        XCTAssertEqual(en0.mac, "a4:83:e7:00:00:01")
        XCTAssertTrue(en0.isUp)
    }

    func testIsUpReflectsAnyRowIsUp() {
        // Mixed up/down rows for the same interface — the interface is "up"
        // if any row reports up.
        let rows: [NetworkManager.RawAddress] = [
            .init(name: "en0", family: .ipv4, address: "10.0.0.1", isUp: false),
            .init(name: "en0", family: .ipv6, address: "fe80::1", isUp: true),
        ]
        let result = NetworkManager.classify(rows: rows).first!
        XCTAssertTrue(result.isUp)
    }

    // MARK: - kind heuristic

    func testKindLoopbackByName() {
        XCTAssertEqual(NetworkManager.kind(forName: "lo0", ipv4: ["127.0.0.1"]), .loopback)
    }

    func testKindThunderboltBridgeRequiresLinkLocalIPv4() {
        XCTAssertEqual(
            NetworkManager.kind(forName: "bridge0", ipv4: ["169.254.10.20"]),
            .thunderboltBridge
        )
        // bridge0 with no link-local v4 is just "other" — could be Internet
        // sharing or a virtualized bridge, not necessarily Thunderbolt.
        XCTAssertEqual(
            NetworkManager.kind(forName: "bridge0", ipv4: ["192.168.64.1"]),
            .other
        )
    }

    func testKindEthernetOrWifiByPrefix() {
        XCTAssertEqual(NetworkManager.kind(forName: "en0", ipv4: []), .ethernetOrWifi)
        XCTAssertEqual(NetworkManager.kind(forName: "en5", ipv4: []), .ethernetOrWifi)
    }

    func testKindVPNByPrefix() {
        XCTAssertEqual(NetworkManager.kind(forName: "utun0", ipv4: []), .vpn)
        XCTAssertEqual(NetworkManager.kind(forName: "ipsec0", ipv4: []), .vpn)
    }

    func testKindOtherFallback() {
        XCTAssertEqual(NetworkManager.kind(forName: "awdl0", ipv4: []), .other)
        XCTAssertEqual(NetworkManager.kind(forName: "gif0", ipv4: []), .other)
        XCTAssertEqual(NetworkManager.kind(forName: "pktap0", ipv4: []), .other)
    }

    // MARK: - summary

    func testInterfaceSummaryFormat() {
        let iface = NetworkInterface(
            name: "bridge0",
            kind: .thunderboltBridge,
            ipv4: ["169.254.10.20"],
            ipv6: ["fe80::1"],
            mac: "a4:83:e7:aa:bb:cc",
            isUp: true
        )
        XCTAssertEqual(
            iface.summary,
            "bridge0 [thunderboltBridge] a4:83:e7:aa:bb:cc 169.254.10.20 fe80::1"
        )
    }

    func testInterfaceSummaryShowsDown() {
        let iface = NetworkInterface(
            name: "en9",
            kind: .ethernetOrWifi,
            ipv4: [],
            ipv6: [],
            mac: nil,
            isUp: false
        )
        XCTAssertEqual(iface.summary, "en9 [ethernetOrWifi] (down)")
    }

    // MARK: - parse(sockaddr:) — direct exercise of the kernel-decode path

    func testParseReturnsNilForNilSockaddr() {
        XCTAssertNil(NetworkManager.parse(name: "en0", isUp: true, sockaddr: nil))
    }

    func testParseDecodesIPv4Sockaddr() {
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr.s_addr = in_addr_t(0x0a0b0c0d).bigEndian // 10.11.12.13
        let result = withUnsafeMutablePointer(to: &sin) { ptr -> NetworkManager.RawAddress? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                NetworkManager.parse(name: "en0", isUp: true, sockaddr: sa)
            }
        }
        XCTAssertEqual(result?.family, .ipv4)
        XCTAssertEqual(result?.address, "10.11.12.13")
    }

    func testParseDecodesIPv6Sockaddr() {
        var sin6 = sockaddr_in6()
        sin6.sin6_family = sa_family_t(AF_INET6)
        // ::1 — loopback. Byte 15 = 1, everything else 0.
        withUnsafeMutablePointer(to: &sin6.sin6_addr) { addrPtr in
            addrPtr.withMemoryRebound(to: UInt8.self, capacity: 16) { bytes in
                for i in 0..<16 { bytes[i] = 0 }
                bytes[15] = 1
            }
        }
        let result = withUnsafeMutablePointer(to: &sin6) { ptr -> NetworkManager.RawAddress? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                NetworkManager.parse(name: "lo0", isUp: true, sockaddr: sa)
            }
        }
        XCTAssertEqual(result?.family, .ipv6)
        XCTAssertEqual(result?.address, "::1")
    }

    func testParseAFLinkWithNonEthernetLengthYieldsNilAddress() {
        // Tunnel / point-to-point links have sdl_alen == 0 (no MAC). The
        // row should still be emitted (family = .link) but with address nil.
        var dl = sockaddr_dl()
        dl.sdl_family = sa_family_t(AF_LINK)
        dl.sdl_nlen = 0
        dl.sdl_alen = 0
        let result = withUnsafeMutablePointer(to: &dl) { ptr -> NetworkManager.RawAddress? in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                NetworkManager.parse(name: "utun0", isUp: true, sockaddr: sa)
            }
        }
        XCTAssertEqual(result?.family, .link)
        XCTAssertNil(result?.address, "AF_LINK with sdl_alen != 6 must yield nil address")
    }

    // MARK: - live smoke test

    /// Smoke test against the real kernel — every Mac has at least `lo0`,
    /// and `lo0` always carries `127.0.0.1` plus the IPv6 loopback `::1`.
    /// Not a behavioural test; just catches "the live enumeration plumbing
    /// got broken."
    func testLiveEnumerationReturnsLoopback() throws {
        let live = NetworkManager.interfaces()
        let lo = live.first { $0.name == "lo0" }
        XCTAssertNotNil(lo, "lo0 must be present on every Mac")
        XCTAssertTrue(lo!.ipv4.contains("127.0.0.1"), "lo0 must carry 127.0.0.1")
        XCTAssertTrue(lo!.ipv6.contains("::1"), "lo0 must carry ::1")
        XCTAssertEqual(lo!.kind, .loopback)
    }
}
