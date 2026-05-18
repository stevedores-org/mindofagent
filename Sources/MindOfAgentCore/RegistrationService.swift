import Foundation

/// POSTs registration payloads to a configurable controller URL.
///
/// Mesh-only mode (controller URL not configured) keeps the service
/// dormant — zero outbound traffic. When the URL *is* set, the service
/// fires a POST on `register(payload:)` and retries with exponential
/// backoff (1s → 2s → 4s → … capped at 5 min) until it succeeds or the
/// next `register()` supersedes it. Failures are surfaced via
/// `lastError` but never crash the app.
///
/// HTTP semantics:
///  - 2xx ⇒ success, retry chain stops, `lastSuccess` updated.
///  - 4xx ⇒ permanent failure, retry chain stops (the controller is
///    rejecting the payload; backing off won't help).
///  - 5xx / transport error ⇒ transient, schedule a retry.
///
/// Designed for dependency-injection: `urlSession` defaults to
/// `URLSession.shared` but tests inject a session with a mock
/// `URLProtocol` to exercise success / 5xx / timeout paths without
/// touching the network.
public actor RegistrationService {
    public let controllerURL: URL
    private let urlSession: URLSession
    private let clock: any Clock<Duration>

    /// Maximum backoff between retries. Backoff starts at 1s and doubles
    /// each failure (1, 2, 4, 8, 16, 32, 64, 128, 256, capped). The cap
    /// is "5 min" per the cheat-codes spec.
    public static let maxBackoff: Duration = .seconds(300)

    public private(set) var lastSuccess: Date?
    public private(set) var lastError: String?
    /// In-flight retry Task, if any. Cancelled when a new `register()`
    /// supersedes it.
    private var retryTask: Task<Void, Never>?

    public init(
        controllerURL: URL,
        urlSession: URLSession = .shared,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.controllerURL = controllerURL
        self.urlSession = urlSession
        self.clock = clock
    }

    deinit {
        retryTask?.cancel()
    }

    /// Fire a registration. Cancels any in-flight retry chain (the new
    /// payload supersedes the previous one) and spawns a fresh attempt
    /// loop. Returns immediately — POSTs happen on a detached Task.
    public func register(payload: RegistrationPayload) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            await self?.runWithRetry(payload: payload)
        }
    }

    /// Cancel the in-flight retry chain without firing a new request.
    /// Used by the AppCoordinator when the user opts out of the controller.
    public func cancel() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func runWithRetry(payload: RegistrationPayload) async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            switch await attempt(payload: payload) {
            case .success:
                lastSuccess = Date()
                lastError = nil
                return
            case .permanentFailure(let message):
                lastError = message
                return
            case .transient(let message):
                lastError = message
                do {
                    try await clock.sleep(for: backoff)
                } catch {
                    return // cancelled mid-sleep
                }
                let doubled = backoff * 2
                backoff = doubled < Self.maxBackoff ? doubled : Self.maxBackoff
            }
        }
    }

    enum AttemptResult {
        case success
        case permanentFailure(String)
        case transient(String)
    }

    private func attempt(payload: RegistrationPayload) async -> AttemptResult {
        var request = URLRequest(url: controllerURL.appendingPathComponent("v1/nodes"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            request.httpBody = try encoder.encode(payload)
        } catch {
            return .permanentFailure("encode failed: \(error.localizedDescription)")
        }

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transient("non-HTTP response")
            }
            switch http.statusCode {
            case 200...299:
                return .success
            case 400...499:
                return .permanentFailure("HTTP \(http.statusCode)")
            default:
                return .transient("HTTP \(http.statusCode)")
            }
        } catch {
            return .transient("transport: \(error.localizedDescription)")
        }
    }
}
