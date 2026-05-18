import Foundation
#if canImport(Darwin)
import Darwin
import Dispatch
import MachO
#endif

/// Samples CPU + memory state. Backed by an actor so concurrent callers
/// can't tear the cached previous-tick state used for CPU deltas.
///
/// CPU is computed from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`:
/// each tick increment in `user + system + nice` is active work; the
/// percentage is `active_delta / total_delta` since the last call. The
/// first call has no prior state so it returns `0%`.
///
/// Memory usage is `(active + wired + compressed) * page_size` from
/// `host_statistics64(HOST_VM_INFO64)`. Memory pressure comes from
/// `DispatchSource.makeMemoryPressureSource` — same source Activity
/// Monitor reads, but as an instantaneous query rather than an event.
public actor TelemetrySampler {

    private var previousTicks: TickSnapshot?

    /// Latched memory pressure level. The DispatchSource fires on
    /// transitions; we keep the last-known level so `sample()` returns the
    /// current value without re-querying.
    private var latchedPressure: MemoryPressure = .normal

    #if canImport(Darwin)
    private let pressureSource: DispatchSourceMemoryPressure
    #endif

    public init() {
        #if canImport(Darwin)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: DispatchQueue.global(qos: .utility)
        )
        self.pressureSource = source
        source.setEventHandler { [weak self] in
            let event = source.data
            let level: MemoryPressure
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warn
            } else {
                level = .normal
            }
            Task { [weak self] in
                await self?.updateLatchedPressure(level)
            }
        }
        source.resume()
        #endif
    }

    deinit {
        #if canImport(Darwin)
        pressureSource.cancel()
        #endif
    }

    public func sample() -> TelemetrySample {
        let cpu = computeCPUPercent()
        let memory = computeMemoryUsedMB()
        return TelemetrySample(
            timestamp: Date(),
            cpuUsagePercent: cpu,
            memoryUsedMB: memory,
            memoryPressure: latchedPressure
        )
    }

    /// Reset the cached tick state — next `sample()` will return `0%` again.
    /// Useful for tests and for pausing/resuming a heartbeat where the gap
    /// would otherwise produce a misleading first reading.
    public func reset() {
        previousTicks = nil
    }

    private func updateLatchedPressure(_ level: MemoryPressure) {
        latchedPressure = level
    }

    // MARK: - CPU

    /// Snapshot of cumulative CPU ticks summed across all cores.
    struct TickSnapshot: Equatable {
        let active: UInt64 // user + system + nice
        let idle: UInt64
    }

    private func computeCPUPercent() -> Double {
        guard let now = readTicks() else { return 0 }
        defer { previousTicks = now }
        guard let prev = previousTicks else { return 0 }

        let activeDelta = now.active &- prev.active
        let idleDelta = now.idle &- prev.idle
        let total = activeDelta + idleDelta
        guard total > 0 else { return 0 }
        return Double(activeDelta) / Double(total) * 100.0
    }

    #if canImport(Darwin)
    private func readTicks() -> TickSnapshot? {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &infoArray,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info = infoArray else { return nil }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var active: UInt64 = 0
        var idle: UInt64 = 0
        let perCPU = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * perCPU
            active &+= UInt64(info[base + Int(CPU_STATE_USER)])
            active &+= UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            active &+= UInt64(info[base + Int(CPU_STATE_NICE)])
            idle &+= UInt64(info[base + Int(CPU_STATE_IDLE)])
        }
        return TickSnapshot(active: active, idle: idle)
    }
    #else
    private func readTicks() -> TickSnapshot? { nil }
    #endif

    // MARK: - Memory

    #if canImport(Darwin)
    private func computeMemoryUsedMB() -> Int {
        var stats = vm_statistics64_data_t()
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = UInt64(vm_kernel_page_size)
        let usedPages = UInt64(stats.active_count)
            &+ UInt64(stats.wire_count)
            &+ UInt64(stats.compressor_page_count)
        let usedBytes = usedPages &* pageSize
        return Int(usedBytes / (1024 * 1024))
    }
    #else
    private func computeMemoryUsedMB() -> Int { 0 }
    #endif
}
