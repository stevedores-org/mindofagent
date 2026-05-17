import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Enumerates host network interfaces by walking the `getifaddrs(3)` linked
/// list and grouping rows by interface name. Each logical interface ends up
/// as a single `NetworkInterface` value carrying every address attached to
/// it, plus a best-effort `Kind` classification.
///
/// Designed to be testable: the public entry point delegates to a pure
/// function that takes a `[RawAddress]` snapshot. Tests build the snapshot
/// in memory and don't hit the kernel.
public enum NetworkManager {

    /// Snapshot the live interface table.
    public static func interfaces() -> [NetworkInterface] {
        classify(rows: enumerateLive())
    }

    // MARK: - Internal: representation + pure classifier

    /// One row of `getifaddrs` — already lowered to plain values so the
    /// pure classifier doesn't need to touch C structs.
    struct RawAddress: Equatable {
        enum Family: Equatable { case ipv4, ipv6, link, other }
        let name: String
        let family: Family
        /// For `ipv4` / `ipv6`: the formatted textual address.
        /// For `link`: the MAC, formatted as colon-separated bytes.
        /// `nil` for `other`.
        let address: String?
        let isUp: Bool
    }

    /// Pure: group rows by interface name and synthesise a `NetworkInterface`
    /// per group. Loopback and unknown-kind rows are still included — callers
    /// can filter if they want only "useful" interfaces.
    static func classify(rows: [RawAddress]) -> [NetworkInterface] {
        // Preserve first-seen order so the public API matches the kernel
        // order (which is what `ifconfig` and friends print).
        var nameOrder: [String] = []
        var grouped: [String: [RawAddress]] = [:]
        for row in rows {
            if grouped[row.name] == nil { nameOrder.append(row.name) }
            grouped[row.name, default: []].append(row)
        }

        return nameOrder.map { name in
            let group = grouped[name] ?? []
            let isUp = group.contains(where: \.isUp)
            let ipv4 = group.compactMap { $0.family == .ipv4 ? $0.address : nil }
            let ipv6 = group.compactMap { $0.family == .ipv6 ? $0.address : nil }
            let mac = group.first { $0.family == .link }?.address
            return NetworkInterface(
                name: name,
                kind: kind(forName: name, ipv4: ipv4),
                ipv4: ipv4,
                ipv6: ipv6,
                mac: mac,
                isUp: isUp
            )
        }
    }

    /// Heuristic classification by interface name + the addresses it carries.
    /// The Thunderbolt-bridge refinement using `SCNetworkInterface` lives in
    /// the #11 issue.
    static func kind(forName name: String, ipv4: [String]) -> NetworkInterface.Kind {
        if name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") { return .vpn }
        if name.hasPrefix("bridge") && ipv4.contains(where: { $0.hasPrefix("169.254.") }) {
            return .thunderboltBridge
        }
        if name.hasPrefix("en") { return .ethernetOrWifi }
        return .other
    }

    // MARK: - Live enumeration (kernel)

    /// Walk the live `getifaddrs(3)` linked list. Best-effort: an unparseable
    /// row is skipped rather than crashing the whole enumeration.
    static func enumerateLive() -> [RawAddress] {
        #if canImport(Darwin)
        var headPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&headPtr) == 0, let head = headPtr else {
            return []
        }
        defer { freeifaddrs(headPtr) }

        var rows: [RawAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let node = cursor {
            let entry = node.pointee
            let name = String(cString: entry.ifa_name)
            let isUp = (entry.ifa_flags & UInt32(IFF_UP)) != 0
            if let row = parse(name: name, isUp: isUp, sockaddr: entry.ifa_addr) {
                rows.append(row)
            }
            cursor = entry.ifa_next
        }
        return rows
        #else
        return []
        #endif
    }

    #if canImport(Darwin)
    /// Convert a single `sockaddr` (already typed by family) into a
    /// printable form. Returns `nil` when the row should be skipped
    /// (null pointer, address-family decode failure).
    ///
    /// `internal` rather than `private` so tests can synthesise sockaddr
    /// values and exercise each branch directly.
    ///
    /// IPv6 caveat: the formatted address does NOT include the
    /// `%scope-id` suffix. `inet_ntop` (unlike `getnameinfo`) never
    /// emits it, so there's nothing to strip — but callers that want
    /// to *connect* to a link-local address (`fe80::*`) will need to
    /// combine `NetworkInterface.name` with `NetworkInterface.ipv6`
    /// to construct a routable endpoint. Will matter for #13
    /// (Registration API client); not relevant for the current
    /// menu / Thunderbolt-classification use cases.
    static func parse(
        name: String,
        isUp: Bool,
        sockaddr: UnsafeMutablePointer<sockaddr>?
    ) -> RawAddress? {
        guard let sa = sockaddr else { return nil }
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                var addr = ptr.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let text: String? = buf.withUnsafeMutableBufferPointer { bp in
                    guard let base = bp.baseAddress,
                          inet_ntop(AF_INET, &addr, base, socklen_t(INET_ADDRSTRLEN)) != nil
                    else {
                        return nil
                    }
                    return String(cString: base)
                }
                guard let text else { return nil }
                return RawAddress(name: name, family: .ipv4, address: text, isUp: isUp)
            }

        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
                var addr = ptr.pointee.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let text: String? = buf.withUnsafeMutableBufferPointer { bp in
                    guard let base = bp.baseAddress,
                          inet_ntop(AF_INET6, &addr, base, socklen_t(INET6_ADDRSTRLEN)) != nil
                    else {
                        return nil
                    }
                    return String(cString: base)
                }
                guard let text else { return nil }
                return RawAddress(name: name, family: .ipv6, address: text, isUp: isUp)
            }

        case AF_LINK:
            return sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { ptr in
                let dl = ptr.pointee
                guard dl.sdl_alen == 6 else {
                    return RawAddress(name: name, family: .link, address: nil, isUp: isUp)
                }
                // `sdl_data` is declared as a 12-byte tuple in the
                // imported header, but the kernel always allocates the
                // full variable-length form (name + addr) inline after
                // the visible struct — so reading `base[nlen .. nlen+5]`
                // for names up to ~12 chars is in-bounds at the kernel
                // allocation, even though Swift sees only 12 declared
                // bytes. The MAC starts at `sdl_data[sdl_nlen]`.
                let nlen = Int(dl.sdl_nlen)
                let bytes = withUnsafePointer(to: dl.sdl_data) { rawPtr in
                    rawPtr.withMemoryRebound(to: UInt8.self, capacity: nlen + 6) { base in
                        (0..<6).map { base[nlen + $0] }
                    }
                }
                let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                return RawAddress(name: name, family: .link, address: mac, isUp: isUp)
            }

        default:
            return RawAddress(name: name, family: .other, address: nil, isUp: isUp)
        }
    }
    #endif
}
