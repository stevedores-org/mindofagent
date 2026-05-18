import Foundation

/// Periodic sampler driver. On `start(interval:)` it spawns a single
/// long-lived `Task` that calls `sampler.sample()` and fans out each
/// result to every configured sink, then sleeps `interval` and repeats
/// until `stop()` is called.
///
/// Actor-backed so concurrent callers (e.g. AppCoordinator init plus a
/// future "restart on config change") can't double-start. The fan-out
/// uses a `TaskGroup` so a slow sink doesn't delay the next tick.
public actor TelemetryHeartbeat {
    public let sampler: TelemetrySampler
    private var sinks: [TelemetrySink]
    private var interval: Duration
    private var task: Task<Void, Never>?

    public init(
        sampler: TelemetrySampler = TelemetrySampler(),
        sinks: [TelemetrySink] = [],
        interval: Duration = .seconds(10)
    ) {
        self.sampler = sampler
        self.sinks = sinks
        self.interval = interval
    }

    public var isRunning: Bool { task != nil }

    /// Append a sink. Safe to call before or after `start()`.
    public func add(sink: TelemetrySink) {
        sinks.append(sink)
    }

    /// Replace the interval. Takes effect after the current sleep
    /// completes — does not interrupt an in-flight tick.
    public func setInterval(_ newInterval: Duration) {
        interval = newInterval
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                guard !Task.isCancelled else { return }
                let sleepDuration = await self.interval
                try? await Task.sleep(for: sleepDuration)
            }
        }
    }

    /// Graceful stop: cancels the loop and waits for any in-flight tick
    /// to finish fanning out before returning. No emit is abandoned
    /// mid-write.
    public func stop() async {
        guard let t = task else { return }
        t.cancel()
        _ = await t.value
        task = nil
    }

    private func tick() async {
        let sample = await sampler.sample()
        let snapshot = sinks
        await withTaskGroup(of: Void.self) { group in
            for sink in snapshot {
                group.addTask { await sink.emit(sample) }
            }
        }
    }
}
