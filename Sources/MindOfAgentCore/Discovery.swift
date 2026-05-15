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
        public var port: UInt16
        public var txtRecord: [String: String]

        public init(hostname: String, port: UInt16 = 52480, txtRecord: [String: String] = [:]) {
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

    public init(config: Config, registry: NodeRegistry = NodeRegistry()) {
        self.config = config
        self.registry = registry
    }

    public func start() throws {
        try advertise()
        browse()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
    }

    // MARK: - Advertise

    private func advertise() throws {
        let params = NWParameters.tcp
        let endpointPort = NWEndpoint.Port(rawValue: config.port) ?? .any
        let listener = try NWListener(using: params, on: endpointPort)
        var txt = config.txtRecord
        txt["host"] = config.hostname
        let descriptor = NWListener.Service(
            name: config.hostname,
            type: Discovery.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord(txt)
        )
        listener.service = descriptor
        listener.newConnectionHandler = { connection in
            // v0: accept and immediately cancel. Health endpoint comes in v0.2.
            connection.cancel()
        }
        listener.start(queue: queue)
        self.listener = listener
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
        let seenIDs = Set(results.map { Discovery.identifier(for: $0) })
        let current = Set(registry.snapshot().nodes.map(\.id))
        for stale in current.subtracting(seenIDs) {
            registry.remove(id: stale)
        }
        for result in results {
            let id = Discovery.identifier(for: result)
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

    // MARK: - Helpers

    static func identifier(for result: NWBrowser.Result) -> String {
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
            return UUID().uuidString
        @unknown default:
            return UUID().uuidString
        }
    }

    static func txtRecord(from result: NWBrowser.Result) -> [String: String] {
        guard case .bonjour(let txt) = result.metadata else { return [:] }
        return txt.dictionary
    }

    static func endpointAddress(_ endpoint: NWEndpoint) -> (host: String, port: Int) {
        switch endpoint {
        case .hostPort(let host, let port):
            return (host: "\(host)", port: Int(port.rawValue))
        case .service(let name, _, _, _):
            return (host: name, port: 0)
        default:
            return (host: "", port: 0)
        }
    }
}
