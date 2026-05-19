import XCTest
@testable import MindOfAgentCore

/// Mock URLProtocol used by the registration tests. Captures every
/// request hitting the test URLSession and responds with a queued
/// (statusCode, error) per call.
final class StubURLProtocol: URLProtocol {

    /// (statusCode, transportError) per call. Pop FIFO. `statusCode=0`
    /// with a non-nil error means transport failure (timeout etc.).
    static let queue = QueueBox()
    static let log = RequestLog()

    final class QueueBox: @unchecked Sendable {
        private var items: [(Int, Error?)] = []
        private let lock = NSLock()
        func enqueue(_ item: (Int, Error?)) {
            lock.lock(); defer { lock.unlock() }
            items.append(item)
        }
        func dequeue() -> (Int, Error?)? {
            lock.lock(); defer { lock.unlock() }
            return items.isEmpty ? nil : items.removeFirst()
        }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            items.removeAll()
        }
    }

    final class RequestLog: @unchecked Sendable {
        private var entries: [URLRequest] = []
        private let lock = NSLock()
        func append(_ req: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            entries.append(req)
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return entries.count
        }
        var first: URLRequest? {
            lock.lock(); defer { lock.unlock() }
            return entries.first
        }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.log.append(request)

        let (status, transportError) = StubURLProtocol.queue.dequeue() ?? (500, nil)

        if let err = transportError {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RegistrationServiceTests: XCTestCase {

    var session: URLSession!

    override func setUp() {
        super.setUp()
        StubURLProtocol.queue.reset()
        StubURLProtocol.log.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.queue.reset()
        StubURLProtocol.log.reset()
        session = nil
        super.tearDown()
    }

    private func makePayload() -> RegistrationPayload {
        RegistrationPayload(
            hostname: "alice-mbp",
            serialNumber: "C02XYZ",
            chip: "Apple M4 Max",
            memoryGB: 64,
            thunderboltIP: "169.254.10.20",
            thunderboltMAC: "00:11:22:33:44:55",
            osVersion: "Version 14.6.1"
        )
    }

    // MARK: - happy path

    func testSuccessful2xxStopsRetries() async throws {
        StubURLProtocol.queue.enqueue((200, nil))

        let service = RegistrationService(
            controllerURL: URL(string: "https://controller.test")!,
            urlSession: session
        )

        await service.register(payload: makePayload())

        // Allow the detached retry task to run.
        try await Task.sleep(for: .milliseconds(50))

        let success = await service.lastSuccess
        let error = await service.lastError
        XCTAssertNotNil(success)
        XCTAssertNil(error)
        XCTAssertEqual(StubURLProtocol.log.count, 1, "no retries after 2xx")
    }

    // MARK: - retry / 5xx

    func testTransient5xxRetriesUntilSuccess() async throws {
        StubURLProtocol.queue.enqueue((503, nil))
        StubURLProtocol.queue.enqueue((503, nil))
        StubURLProtocol.queue.enqueue((200, nil))

        let service = RegistrationService(
            controllerURL: URL(string: "https://controller.test")!,
            urlSession: session,
            clock: ImmediateClock() // skip the real backoff sleep
        )

        await service.register(payload: makePayload())

        // Three attempts: poll until lastSuccess is set or we time out.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await service.lastSuccess != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let success = await service.lastSuccess
        XCTAssertNotNil(success, "retry chain must eventually succeed")
        XCTAssertEqual(StubURLProtocol.log.count, 3, "two 5xx retries + final 200")
    }

    // MARK: - permanent failure

    func test4xxStopsRetryingImmediately() async throws {
        StubURLProtocol.queue.enqueue((401, nil))

        let service = RegistrationService(
            controllerURL: URL(string: "https://controller.test")!,
            urlSession: session,
            clock: ImmediateClock()
        )

        await service.register(payload: makePayload())
        try await Task.sleep(for: .milliseconds(80))

        let success = await service.lastSuccess
        let error = await service.lastError
        XCTAssertNil(success)
        XCTAssertEqual(error, "HTTP 401")
        XCTAssertEqual(StubURLProtocol.log.count, 1, "4xx must not retry")
    }

    // MARK: - transport error

    func testTransportErrorIsTransient() async throws {
        let timeoutError = URLError(.timedOut)
        StubURLProtocol.queue.enqueue((0, timeoutError))
        StubURLProtocol.queue.enqueue((200, nil))

        let service = RegistrationService(
            controllerURL: URL(string: "https://controller.test")!,
            urlSession: session,
            clock: ImmediateClock()
        )

        await service.register(payload: makePayload())

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await service.lastSuccess != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let success = await service.lastSuccess
        XCTAssertNotNil(success, "transport errors must trigger retry, then succeed")
        XCTAssertEqual(StubURLProtocol.log.count, 2, "one transport-error retry + final 200")
    }

    // MARK: - cancel

    func testCancelStopsInFlightRetry() async throws {
        // Enqueue many 5xx so the retry chain would run indefinitely
        // without cancel(). With the cancellation-aware ImmediateClock
        // below, the loop is fast but cooperatively cancellable.
        for _ in 0..<100 { StubURLProtocol.queue.enqueue((503, nil)) }

        let service = RegistrationService(
            controllerURL: URL(string: "https://controller.test")!,
            urlSession: session,
            clock: ImmediateClock()
        )

        await service.register(payload: makePayload())
        try await Task.sleep(for: .milliseconds(30))
        await service.cancel()

        // After cancel, request count should freeze. A small grace
        // window accommodates any single in-flight HTTP request that
        // had crossed the network layer before cancellation hit.
        let countAfterCancel = StubURLProtocol.log.count
        try await Task.sleep(for: .milliseconds(100))
        let drift = StubURLProtocol.log.count - countAfterCancel
        XCTAssertLessThanOrEqual(drift, 1, "at most one in-flight request straggles past cancel")
    }

    // MARK: - body shape

    func testPayloadIsPOSTedAsJSON() async throws {
        StubURLProtocol.queue.enqueue((200, nil))

        let service = RegistrationService(
            controllerURL: URL(string: "https://controller.test")!,
            urlSession: session
        )

        await service.register(payload: makePayload())
        try await Task.sleep(for: .milliseconds(50))

        let req = StubURLProtocol.log.first
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req?.url?.path, "/v1/nodes")

        // URLProtocol surfaces the body via the stream property — read it.
        let body = req?.httpBody ?? Data(reading: req?.httpBodyStream)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["hostname"] as? String, "alice-mbp")
        XCTAssertEqual(json["serial_number"] as? String, "C02XYZ")
        XCTAssertEqual(json["chip"] as? String, "Apple M4 Max")
        XCTAssertEqual(json["memory_gb"] as? Int, 64)
        XCTAssertEqual(json["thunderbolt_ip"] as? String, "169.254.10.20")
        XCTAssertEqual(json["thunderbolt_mac"] as? String, "00:11:22:33:44:55")
        XCTAssertEqual(json["os_version"] as? String, "Version 14.6.1")
    }
}

/// A `Clock` that reports zero elapsed time and skips every `sleep(for:)`
/// call. Lets the retry tests verify the backoff *sequence* without
/// burning real wall time waiting for 1s + 2s + 4s + ... backoffs.
///
/// `sleep` still honors task cancellation via `checkCancellation()` — the
/// production loop relies on the sleep throwing CancellationError when
/// the retry chain is cancelled, and a zero-cost sleep that ignores
/// cancellation would let the loop spin at machine speed past a cancel().
private struct ImmediateClock: Clock {
    var now: ContinuousClock.Instant { .now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}

/// Helper: URLProtocol exposes the body either via `httpBody` (for small
/// bodies) or `httpBodyStream` (when the session re-streams it). Read
/// whichever is populated.
private extension Data {
    init(reading stream: InputStream?) {
        guard let stream else { self.init(); return }
        stream.open()
        defer { stream.close() }
        var buf = [UInt8](repeating: 0, count: 4096)
        var collected = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: buf.count)
            if read <= 0 { break }
            collected.append(buf, count: read)
        }
        self = collected
    }
}
