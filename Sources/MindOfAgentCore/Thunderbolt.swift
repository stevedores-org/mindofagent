import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

extension NetworkManager {

    /// Returns the Thunderbolt Bridge interface, or `nil` when no
    /// Thunderbolt-bridge-shaped interface is currently live.
    ///
    /// Selection algorithm:
    /// 1. Take every interface classified as `.thunderboltBridge` by
    ///    `NetworkManager.classify(rows:)` — name `bridge*` carrying a
    ///    link-local IPv4 in 169.254/16. `classify` preserves kernel
    ///    order, so the first match is the canonical `bridge0`.
    /// 2. Cross-check via `SCNetworkInterface`: prefer a candidate
    ///    whose interface type is `kSCNetworkInterfaceTypeBridge`
    ///    (filters out the rare cases where a non-bridge interface
    ///    name starts with "bridge"). When SC is unavailable or the
    ///    check is inconclusive, fall back to the heuristic-only match.
    public static func thunderboltBridge() -> NetworkInterface? {
        let candidates = interfaces().filter { $0.kind == .thunderboltBridge }
        guard !candidates.isEmpty else { return nil }

        // If SC can confirm any candidate is a bridge, return the first
        // such confirmation. Otherwise trust the heuristic and return
        // the first candidate.
        for candidate in candidates where isBridgeInterface(named: candidate.name) {
            return candidate
        }
        return candidates.first
    }

    /// `true` if `SCNetworkInterface` reports the named BSD interface as
    /// a bridge (`kSCNetworkInterfaceTypeBridge`). `false` when SC isn't
    /// available, the name isn't enumerated, or the type doesn't match.
    ///
    /// Note: full Thunderbolt member-port introspection requires
    /// `SCBridgeInterfaceCopyMemberInterfaces` which is not exposed in
    /// the Swift overlay of SystemConfiguration. The bridge-type check
    /// is the strongest assertion we can make from public API; the
    /// heuristic in `classify` (name + 169.254 IPv4) carries the rest.
    public static func isBridgeInterface(named name: String) -> Bool {
        #if canImport(SystemConfiguration)
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return false
        }
        // The Swift overlay of SystemConfiguration doesn't expose the
        // `kSCNetworkInterface*` `CFString` constants, so we compare
        // against the documented literal type string. Apple docs:
        // `SCNetworkInterfaceGetInterfaceType` returns one of "Ethernet",
        // "FireWire", "IEEE80211", "Bridge", "Bond", "PPP", "VLAN",
        // "WWAN", "IPSec".
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String?, bsd == name,
                  let type = SCNetworkInterfaceGetInterfaceType(iface) as String?
            else { continue }
            return type == "Bridge"
        }
        return false
        #else
        return false
        #endif
    }
}
