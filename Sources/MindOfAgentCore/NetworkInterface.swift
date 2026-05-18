import Foundation

/// Represents a single network interface present on the host.
///
/// A logical interface (`en0`, `bridge0`, …) can carry multiple addresses
/// (an IPv4 + several IPv6 link-locals, for example). `ipv4` and `ipv6`
/// collect them; `mac` is captured separately because it comes from the
/// link-layer `AF_LINK` row of `getifaddrs`.
public struct NetworkInterface: Equatable, Sendable {
    /// Best-effort classification of an interface. Used by the menu's
    /// Network section and by Thunderbolt-bridge identification (#11).
    public enum Kind: String, Sendable, Equatable {
        /// `lo0` — the loopback interface.
        case loopback
        /// `en*` carrying an active address. macOS does not distinguish
        /// Wi-Fi vs Ethernet at the `getifaddrs` layer; refining this to
        /// `wifi` vs `ethernet` requires `SCNetworkInterface`, which is
        /// out of scope for #10 (the Thunderbolt-aware refinement lands
        /// in #11).
        case ethernetOrWifi
        /// `bridge*` carrying a link-local IPv4 in 169.254/16 — the
        /// shape Apple's auto-configured Thunderbolt Bridge takes. This
        /// is the *heuristic* match used by `NetworkManager`; #11 will
        /// cross-check with `SCNetworkInterface` member-port info.
        case thunderboltBridge
        /// `utun*` / `ipsec*` — VPN tunnels and IPsec interfaces.
        case vpn
        /// Anything else (`awdl*`, `pktap*`, `gif*`, vendor-specific names).
        case other
    }

    public let name: String
    public let kind: Kind
    public let ipv4: [String]
    public let ipv6: [String]
    /// Colon-separated link-layer address (e.g. `"a4:83:e7:00:00:01"`).
    /// `nil` for interfaces with no link-layer row (loopback, VPN tunnels).
    public let mac: String?
    /// `IFF_UP` from `getifaddrs`. An interface can be "up" (driver
    /// attached) without having an address — those are still listed.
    public let isUp: Bool

    public init(
        name: String,
        kind: Kind,
        ipv4: [String],
        ipv6: [String],
        mac: String?,
        isUp: Bool
    ) {
        self.name = name
        self.kind = kind
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.mac = mac
        self.isUp = isUp
    }
}

extension NetworkInterface {
    /// One-line human-readable form used by the `mindofagent ifaces`
    /// CLI subcommand and by the menu's debug Network section.
    public var summary: String {
        var parts: [String] = ["\(name) [\(kind.rawValue)]"]
        if !isUp { parts.append("(down)") }
        if let mac { parts.append(mac) }
        parts.append(contentsOf: ipv4)
        parts.append(contentsOf: ipv6)
        return parts.joined(separator: " ")
    }
}
