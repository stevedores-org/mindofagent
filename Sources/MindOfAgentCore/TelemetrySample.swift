import Foundation

/// One-shot host telemetry — what `TelemetrySampler.sample()` returns. All
/// values reflect the *delta since the previous sample* (for CPU) or the
/// instantaneous reading (for memory).
public struct TelemetrySample: Equatable, Sendable {
    public let timestamp: Date
    /// 0–100. The percentage of CPU time spent in user + system + nice
    /// across all cores since the previous sample. The very first sample
    /// from a sampler is `0` because there is no prior tick state.
    public let cpuUsagePercent: Double
    public let memoryUsedMB: Int
    public let memoryPressure: MemoryPressure

    public init(
        timestamp: Date,
        cpuUsagePercent: Double,
        memoryUsedMB: Int,
        memoryPressure: MemoryPressure
    ) {
        self.timestamp = timestamp
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsedMB = memoryUsedMB
        self.memoryPressure = memoryPressure
    }
}

/// macOS memory pressure bucket — what `DISPATCH_MEMORYPRESSURE_*` flags
/// resolve to. Matches the three levels Activity Monitor's memory-pressure
/// graph uses.
public enum MemoryPressure: String, Sendable, Equatable {
    case normal
    case warn
    case critical
}
