import Foundation
#if canImport(Darwin)
import Darwin
import IOKit
#endif

/// Static, host-identifying facts that don't change at runtime — captured
/// once and republished via Bonjour TXT records so peers see chip + memory
/// in the menu without an HTTP probe.
///
/// All optional fields can be `nil` when the underlying source fails
/// (sandboxed environment, sysctl missing, IOKit denied, etc.). Callers
/// should degrade gracefully — for example, fall back to the hostname-only
/// TXT shape used in v0.
public struct HardwareProfile: Equatable, Sendable {
    public let hostname: String
    /// e.g. `"Apple M4 Max"` on Apple Silicon, or `"Intel Core i9"` on Intel.
    /// `nil` if `machdep.cpu.brand_string` can't be read.
    public let chip: String?
    /// Rounded up from `hw.memsize` (raw bytes). `64` for a 64 GB machine.
    public let memoryGB: Int?
    /// IOKit `IOPlatformSerialNumber`. Personally identifying — kept out of
    /// the default Bonjour TXT advertisement (see `txtRecord`).
    public let serialNumber: String?
    /// e.g. `"Version 14.6.1 (Build 23G93)"`.
    public let osVersion: String
    /// e.g. `"MacBookPro18,4"` — Apple's internal model identifier.
    public let model: String?

    public init(
        hostname: String,
        chip: String?,
        memoryGB: Int?,
        serialNumber: String?,
        osVersion: String,
        model: String?
    ) {
        self.hostname = hostname
        self.chip = chip
        self.memoryGB = memoryGB
        self.serialNumber = serialNumber
        self.osVersion = osVersion
        self.model = model
    }
}

extension HardwareProfile {
    /// Bonjour TXT record shape published with `Discovery`. Only includes
    /// fields safe to broadcast over the LAN — serialNumber is intentionally
    /// omitted (personally identifying, peers don't need it for routing).
    public var txtRecord: [String: String] {
        var t: [String: String] = ["host": hostname]
        if let chip { t["chip"] = chip }
        if let memoryGB { t["mem_gb"] = String(memoryGB) }
        if let model { t["model"] = model }
        return t
    }
}

public enum HardwareProfiler {

    /// Capture every host-identifying fact in one go. Cheap (a handful of
    /// sysctl + IOKit calls) so it's fine to call at app launch and on every
    /// resume.
    public static func getProfile() -> HardwareProfile {
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        #if canImport(Darwin)
        let chip = sysctlString("machdep.cpu.brand_string")
        let memBytes = sysctlUInt64("hw.memsize")
        let memoryGB = memBytes.map { Int(($0 + (1 << 30) - 1) >> 30) } // ceil to GB
        let model = sysctlString("hw.model")
        let serialNumber = readIOPlatformSerialNumber()
        #else
        let chip: String? = nil
        let memoryGB: Int? = nil
        let model: String? = nil
        let serialNumber: String? = nil
        #endif

        return HardwareProfile(
            hostname: hostname,
            chip: chip,
            memoryGB: memoryGB,
            serialNumber: serialNumber,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            model: model
        )
    }

    // MARK: - sysctl helpers

    #if canImport(Darwin)
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        // Trim the trailing NUL that sysctl includes in `size`.
        let text = String(cString: buf)
        return text.isEmpty ? nil : text
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func readIOPlatformSerialNumber() -> String? {
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let property = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformSerialNumber" as CFString,
            kCFAllocatorDefault,
            0
        )
        return (property?.takeRetainedValue() as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
