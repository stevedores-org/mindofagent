import XCTest
@testable import MindOfAgentCore

final class TelemetrySamplerTests: XCTestCase {

    func testFirstSampleReportsZeroCPU() async {
        let sampler = TelemetrySampler()
        let sample = await sampler.sample()

        // No prior tick state ⇒ CPU delta can't be computed yet.
        XCTAssertEqual(sample.cpuUsagePercent, 0, accuracy: 0.001)
    }

    func testSubsequentSampleReportsRealCPU() async throws {
        let sampler = TelemetrySampler()
        _ = await sampler.sample() // seed

        // Burn some CPU so the next delta is non-trivially > 0. 50 ms of a
        // tight loop on any reasonable Mac is plenty to flip ticks.
        let burnDeadline = Date().addingTimeInterval(0.05)
        var counter: UInt64 = 0
        while Date() < burnDeadline {
            counter &+= 1
        }
        XCTAssertGreaterThan(counter, 0, "loop ran")

        let sample = await sampler.sample()
        XCTAssertGreaterThanOrEqual(sample.cpuUsagePercent, 0)
        XCTAssertLessThanOrEqual(sample.cpuUsagePercent, 100)
    }

    func testResetClearsPreviousTickState() async {
        let sampler = TelemetrySampler()
        _ = await sampler.sample()
        _ = await sampler.sample() // would be non-zero in principle

        await sampler.reset()
        let after = await sampler.sample()
        XCTAssertEqual(after.cpuUsagePercent, 0, accuracy: 0.001,
                       "post-reset first sample is 0% again")
    }

    func testMemoryUsedIsNonZero() async {
        let sampler = TelemetrySampler()
        let sample = await sampler.sample()

        // Any running macOS test process has hundreds of MB of memory used.
        // Sanity: it's at least 1 MB and at most TB scale.
        XCTAssertGreaterThan(sample.memoryUsedMB, 1)
        XCTAssertLessThan(sample.memoryUsedMB, 1024 * 1024) // < 1 TB
    }

    func testInitialMemoryPressureIsNormal() async {
        // The DispatchSource fires on transitions; until one fires, we keep
        // the default `.normal` latched state.
        let sampler = TelemetrySampler()
        let sample = await sampler.sample()
        XCTAssertEqual(sample.memoryPressure, .normal)
    }

    func testConcurrentSamplesAreSerialised() async {
        // Hammer sample() from many tasks. The actor must serialise so
        // every call returns a well-formed value (no torn tick state).
        let sampler = TelemetrySampler()
        await withTaskGroup(of: TelemetrySample.self) { group in
            for _ in 0..<32 {
                group.addTask { await sampler.sample() }
            }
            var count = 0
            for await result in group {
                count += 1
                XCTAssertGreaterThanOrEqual(result.cpuUsagePercent, 0)
                XCTAssertLessThanOrEqual(result.cpuUsagePercent, 100)
                XCTAssertGreaterThan(result.memoryUsedMB, 0)
            }
            XCTAssertEqual(count, 32)
        }
    }
}
