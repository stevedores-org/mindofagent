import Foundation
import Network

/// Bonjour advertiser + browser for `_mindofagent._tcp`.
///
/// Each node publishes itself and watches for peers on the same link-local
/// network. When the Thunderbolt Bridge is up between Macs, they are on the
/// same subnet and discover each other with no manual configuration.
public final class Discovery: @unchecked Sendable {
    public static let serviceType = "_mindofagent._tcp"

    public struct Config: Sendable {
        public var hostname: String
        /// TCP port for the advertise listener. `0` (default) ⇒ kernel
        /// picks a free ephemeral port. A non-zero preferred port is
        /// honored when free, otherwise binding fails and `start()`
        /// throws — avoid hardcoded ports unless you actually need
        /// a fixed one. Bonjour publishes the actual bound port
        /// regardless, so peers always resolve correctly.
        public var port: UInt16
        public var txtRecord: [String: String]

        public init(hostname: String, port: UInt16 = 0, txtRecord: [String: String] = [:]) {
            self.hostname = hostname
            self.port = port
            self.txtRecord = txtRecord
        }
    }

    public let registry: NodeRegistry
    private let config: Config
    private let queue = DispatchQueue(label: "io.stevedores.mindofagent.discovery")
    private var listener: NWListener?
    private var browser: NWBrowser?
    /// Current live TXT record. Starts as `config.txtRecord` augmented
    /// with `host`; mutated by `updateTXT(_:)`. Held on the discovery
    /// queue so updates from any thread serialise.
    private var liveTXT: [String: String]

    public init(config: Config, registry: NodeRegistry = NodeRegistry()) {
        self.config = config
        self.registry = registry
        var initial = config.txtRecord
        initial["host"] = config.hostname
        self.liveTXT = initial
    }

    public func start() throws {
        // Route start/stop through the discovery queue so listener/browser
        // mutations serialise with the queue's other consumers (browse
        // callbacks, updateTXT). Without this, a UI thread calling
        // stop() during an in-flight browse callback could race the
        // listener/browser pointers.
        try queue.sync {
            try advertise()
            browse()
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            browser?.cancel()
            browser = nil
        }
    }

    // MARK: - Advertise

    private func advertise() throws {
        let params = NWParameters.tcp
        // port = 0 ⇒ `.any` (kernel picks ephemeral). A configured
        // non-zero port is honored when free; if it's held, `try NWListener(...)`
        // throws and `start()` surfaces that to `AppCoordinator.startupError`.
        let endpointPort: NWEndpoint.Port = config.port == 0
            ? .any
            : (NWEndpoint.Port(rawValue: config.port) ?? .any)
        let listener = try NWListener(using: params, on: endpointPort)
        listener.service = makeServiceDescriptor(txt: liveTXT)
        listener.newConnectionHandler = { connection in
            // v0: accept and immediately cancel. Health endpoint comes in v0.2.
            connection.cancel()
        }
        // Once the listener resolves a real port (kernel-assigned or
        // requested), publish it as a TXT entry so peers can read the
        // port without relying on NWConnection-based resolution. The
        // stateUpdateHandler fires on the discovery queue.
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            if let actual = listener.port {
                self.queue.async {
                    self.liveTXT["port"] = String(actual.rawValue)
                    listener.service = self.makeServiceDescriptor(txt: self.liveTXT)
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func makeServiceDescriptor(txt: [String: String]) -> NWListener.Service {
        NWListener.Service(
            name: config.hostname,
            type: Discovery.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord(txt)
        )
    }

    /// Merge `additions` into the live TXT record and re-publish the
    /// service. Setting `listener.service` triggers Bonjour to send a
    /// goodbye + fresh announcement, so peers see the updated record
    /// within the next browse callback.
    ///
    /// Existing keys are overwritten; non-overlapping keys are preserved.
    /// `host` is restored to `config.hostname` if a caller tries to
    /// overwrite it — the hostname is identity, not a per-tick value.
    ///
    /// **Precondition: `start()` has been called.** If the listener
    /// hasn't been created yet, the update silently no-ops — there is
    /// no service to publish to. Callers that wire a sink before
    /// `start()` (e.g. `TelemetryHeartbeat` configured at `init` time)
    /// must rely on the heartbeat interval being long enough that
    /// `start()` lands first, or sequence the calls explicitly.
    public func updateTXT(_ additions: [String: String]) {
        queue.async { [self] in
            guard let listener else { return }
            for (key, value) in additions {
                liveTXT[key] = value
            }
            liveTXT["host"] = config.hostname
            listener.service = makeServiceDescriptor(txt: liveTXT)
        }
    }

    // MARK: - Browse

    private func browse() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: Discovery.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handle(results: Set<NWBrowser.Result>) {
        // Skip results we can't derive a stable id from (`.opaque` / `@unknown`).
        // Otherwise each browse callback would mint a fresh UUID for the same
        // endpoint and the stale-cleanup loop would never converge.
        //
        // Also skip our own advertisement — a node always sees itself in its
        // own browse results, and listing self as a "peer" inflates the menu
        // count and confuses single-machine launches.
        let identified: [(id: String, result: NWBrowser.Result)] =
            results.compactMap { result in
                guard let id = Discovery.identifier(for: result) else { return nil }
                if Discovery.isSelf(result: result, hostname: config.hostname) {
                    return nil
                }
                return (id, result)
            }

        let seenIDs = Set(identified.map(\.id))
        let current = Set(registry.snapshot().nodes.map(\.id))
        for stale in current.subtracting(seenIDs) {
            registry.remove(id: stale)
        }
        for (id, result) in identified {
            let txt = Discovery.txtRecord(from: result)
            let (host, port) = Discovery.endpointAddress(result.endpoint)
            let displayHost = txt["host"] ?? id
            registry.upsert(
                Node(
                    id: id,
                    hostname: displayHost,
                    host: host,
                    port: port,
                    txtRecord: txt
                )
            )
        }
    }

    /// `true` if the browse result is this node's own advertisement.
    /// Compares the Bonjour service name (which `NWListener.Service`
    /// publishes as `config.hostname`) against our own hostname. mDNS
    /// auto-suffixes name collisions (`alice` → `alice-2`), so this is
    /// a name-prefix match in the rare suffix case.
    static func isSelf(result: NWBrowser.Result, hostname: String) -> Bool {
        guard case .service(let name, _, _, _) = result.endpoint else {
            return false
        }
        return name == hostname
    }

    // MARK: - Helpers

    /// Return a stable id derived from the endpoint, or `nil` if the endpoint
    /// kind can't be mapped to a deterministic identifier. `nil` is what
    /// signals `handle(results:)` to skip the result rather than synthesising
    /// a UUID that would never stay stable across callbacks.
    static func identifier(for result: NWBrowser.Result) -> String? {
        switch result.endpoint {
        case .service(let name, let type, let domain, _):
            return "\(name).\(type)\(domain)"
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .unix(let path):
            return path
        case .url(let url):
            return url.absoluteString
        case .opaque:
            return nil
        @unknown default:
            return nil
        }
    }

    static func txtRecord(from result: NWBrowser.Result) -> [String: String] {
        guard case .bonjour(let txt) = result.metadata else { return [:] }
        return txt.dictionary
    }

    /// Extract a `(host, port)` from an `NWEndpoint` for storage in
    /// `Node.host` / `Node.port`. For `.service` endpoints we return an
    /// **empty** host: Bonjour browse results are not pre-resolved, so
    /// the service "name" is not a routable host. A future caller that
    /// needs to actually dial a peer must run `NWConnection`-based
    /// resolution on the endpoint — or read the host from the TXT
    /// record (where the peer publishes a resolvable form via the
    /// `host` key set by `Discovery.advertise`).
    static func endpointAddress(_ endpoint: NWEndpoint) -> (host: String, port: Int) {
        switch endpoint {
        case .hostPort(let host, let port):
            return (host: "\(host)", port: Int(port.rawValue))
        case .service:
            return (host: "", port: 0)
        default:
            return (host: "", port: 0)
        }
    }
}
