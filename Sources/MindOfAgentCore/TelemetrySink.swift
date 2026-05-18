import Foundation

/// Where a `TelemetryHeartbeat` tick lands. Implementations can be
/// trivial (log to stdout) or wire to a real consumer (refresh Bonjour
/// TXT records, POST to a controller URL — see #13).
public protocol TelemetrySink: Sendable {
    func emit(_ sample: TelemetrySample) async
}

// MARK: - Built-in sinks

/// Drops the sample on the floor. Useful as a default when telemetry
/// is configured but no real sink has been wired yet.
public struct NullTelemetrySink: TelemetrySink {
    public init() {}
    public func emit(_ sample: TelemetrySample) async {}
}

/// Refreshes Bonjour TXT records on a `Discovery` instance. Updates the
/// `cpu_pct`, `mem_used_mb`, and `mem_pressure` keys so peers can read
/// live values from browse callbacks without an HTTP probe.
///
/// `cpu_pct` is formatted to one decimal place — TXT records are size-
/// limited and the extra precision isn't useful.
public final class BonjourTXTSink: TelemetrySink {
    private let discovery: Discovery

    public init(discovery: Discovery) {
        self.discovery = discovery
    }

    public func emit(_ sample: TelemetrySample) async {
        discovery.updateTXT([
            "cpu_pct": String(format: "%.1f", sample.cpuUsagePercent),
            "mem_used_mb": String(sample.memoryUsedMB),
            "mem_pressure": sample.memoryPressure.rawValue,
        ])
    }
}

/// Captures every sample into an internal array. Used by tests; not
/// intended for production (no upper bound on memory growth).
public actor RecordingTelemetrySink: TelemetrySink {
    public private(set) var samples: [TelemetrySample] = []

    public init() {}

    public func emit(_ sample: TelemetrySample) async {
        samples.append(sample)
    }
}
