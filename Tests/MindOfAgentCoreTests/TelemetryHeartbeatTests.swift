import XCTest
@testable import MindOfAgentCore

final class TelemetryHeartbeatTests: XCTestCase {

    func testStartFansOutToEverySinkPerTick() async {
        // Two recording sinks, a 50ms interval, run for ~250ms — expect
        // at least 3 fan-outs to each sink. Generous bounds because the
        // tick cadence is "≥ interval", not exact.
        let s1 = RecordingTelemetrySink()
        let s2 = RecordingTelemetrySink()
        let hb = TelemetryHeartbeat(
            sinks: [s1, s2],
            interval: .milliseconds(50)
        )

        await hb.start()
        try? await Task.sleep(for: .milliseconds(250))
        await hb.stop()

        let n1 = await s1.samples.count
        let n2 = await s2.samples.count
        XCTAssertGreaterThanOrEqual(n1, 3, "sink 1 received \(n1) ticks")
        XCTAssertGreaterThanOrEqual(n2, 3, "sink 2 received \(n2) ticks")
        XCTAssertEqual(n1, n2, "every tick must reach every sink")
    }

    func testStopIsGracefulNoAbandonedEmit() async {
        let sink = RecordingTelemetrySink()
        let hb = TelemetryHeartbeat(sinks: [sink], interval: .milliseconds(20))

        await hb.start()
        try? await Task.sleep(for: .milliseconds(100))
        await hb.stop()

        // After stop returns, no new ticks should land — the count we
        // observe now must equal the count a moment later.
        let countAfterStop = await sink.samples.count
        try? await Task.sleep(for: .milliseconds(100))
        let countLater = await sink.samples.count
        XCTAssertEqual(countAfterStop, countLater, "no ticks after stop")
        XCTAssertGreaterThan(countAfterStop, 0)
    }

    func testIsRunningReflectsStartStop() async {
        let hb = TelemetryHeartbeat(interval: .milliseconds(50))
        var running = await hb.isRunning
        XCTAssertFalse(running)

        await hb.start()
        running = await hb.isRunning
        XCTAssertTrue(running)

        await hb.stop()
        running = await hb.isRunning
        XCTAssertFalse(running)
    }

    func testDoubleStartIsNoOp() async {
        // Two .start() calls must not spawn two parallel loops — that
        // would double the tick rate and burn 2x CPU.
        let sink = RecordingTelemetrySink()
        let hb = TelemetryHeartbeat(sinks: [sink], interval: .milliseconds(50))

        await hb.start()
        await hb.start()
        try? await Task.sleep(for: .milliseconds(220))
        await hb.stop()

        let count = await sink.samples.count
        // 220ms / 50ms ≈ 4-5 ticks. If we accidentally started two
        // loops, we'd see ~8-10. 6 is the safe upper bound.
        XCTAssertLessThanOrEqual(count, 6, "double start spawned a second loop")
    }

    func testAddSinkBeforeAndAfterStart() async {
        let s1 = RecordingTelemetrySink()
        let s2 = RecordingTelemetrySink()
        let hb = TelemetryHeartbeat(sinks: [s1], interval: .milliseconds(40))

        await hb.start()
        try? await Task.sleep(for: .milliseconds(100))
        await hb.add(sink: s2)
        try? await Task.sleep(for: .milliseconds(150))
        await hb.stop()

        let n1 = await s1.samples.count
        let n2 = await s2.samples.count
        XCTAssertGreaterThan(n1, n2, "s1 was running longer and must have more samples")
        XCTAssertGreaterThan(n2, 0, "s2 must receive ticks once added")
    }
}
