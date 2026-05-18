import Foundation

/// JSON body POSTed to `${controllerURL}/v1/nodes` by `RegistrationService`.
/// Field names use snake_case to match the controller's expected schema
/// (defined in the cheat-codes TDD).
public struct RegistrationPayload: Codable, Equatable, Sendable {
    public let hostname: String
    public let serialNumber: String?
    public let chip: String?
    public let memoryGB: Int?
    public let thunderboltIP: String?
    public let thunderboltMAC: String?
    public let osVersion: String

    private enum CodingKeys: String, CodingKey {
        case hostname
        case serialNumber = "serial_number"
        case chip
        case memoryGB = "memory_gb"
        case thunderboltIP = "thunderbolt_ip"
        case thunderboltMAC = "thunderbolt_mac"
        case osVersion = "os_version"
    }

    public init(
        hostname: String,
        serialNumber: String?,
        chip: String?,
        memoryGB: Int?,
        thunderboltIP: String?,
        thunderboltMAC: String?,
        osVersion: String
    ) {
        self.hostname = hostname
        self.serialNumber = serialNumber
        self.chip = chip
        self.memoryGB = memoryGB
        self.thunderboltIP = thunderboltIP
        self.thunderboltMAC = thunderboltMAC
        self.osVersion = osVersion
    }

    /// Compose a payload from a `HardwareProfile` and an optional
    /// `NetworkInterface` (the Thunderbolt bridge, when connected).
    public init(
        hardware: HardwareProfile,
        thunderbolt: NetworkInterface?
    ) {
        self.init(
            hostname: hardware.hostname,
            serialNumber: hardware.serialNumber,
            chip: hardware.chip,
            memoryGB: hardware.memoryGB,
            thunderboltIP: thunderbolt?.ipv4.first,
            thunderboltMAC: thunderbolt?.mac,
            osVersion: hardware.osVersion
        )
    }
}
