import Foundation
import MindOfAgentCore

/// Process entry point. Inspects `CommandLine.arguments` for CLI subcommands
/// before falling through to the SwiftUI app, so debugging from a terminal
/// (`mindofagent ifaces`) doesn't require launching the menu-bar UI.
@main
enum AppEntry {
    static func main() {
        // v0 arg parser: only inspects `args[1]`. Trailing args are
        // ignored (e.g. `mindofagent ifaces --verbose` silently drops
        // `--verbose`). When subcommands grow flags, swap in
        // ArgumentParser; for now the surface is too small to need it.
        let args = CommandLine.arguments
        if args.count >= 2 {
            switch args[1] {
            case "ifaces":
                runIfacesSubcommand()
                exit(0)
            case "--daemon":
                runDaemon() // never returns; blocks on RunLoop.main
            case "--help", "-h", "help":
                printUsage()
                exit(0)
            case "--version", "-v", "version":
                print("mindofagent \(Self.version)")
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown subcommand: \(args[1])\n".utf8))
                printUsage()
                exit(64) // EX_USAGE
            }
        }
        MindOfAgentApp.main()
    }

    /// Build-time version string. Bumped at release time alongside the
    /// git tag. Read by `mindofagent --version` and could feed a
    /// `version` TXT-record key in a future release.
    static let version = "1.0.0"

    private static func runIfacesSubcommand() {
        for iface in NetworkManager.interfaces() {
            print(iface.summary)
        }
    }

    /// Headless mode used by `com.stevedores.mindofagent` LaunchDaemon.
    /// No SwiftUI, no MenuBarExtra — just Discovery + NodeRegistry + the
    /// host hardware profile, advertised over Bonjour, with a forever
    /// RunLoop so the dispatch queues driving NWListener/NWBrowser keep
    /// firing. Suitable for headless cluster nodes (mac-mini boxes
    /// without a logged-in user).
    private static func runDaemon() -> Never {
        // LaunchDaemons run as root with no logged-in user, so
        // Host.current().localizedName may return the machine's
        // unmodified hostname (e.g. "macmini-01.local"). Fine for
        // mesh identification.
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let registry = NodeRegistry()
        let config = Discovery.Config(hostname: hostname)
        let discovery = Discovery(config: config, registry: registry)

        do {
            try discovery.start()
        } catch {
            let msg = "mindofagent --daemon: discovery start failed: \(error)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(1)
        }

        print("mindofagent --daemon: started, host=\(hostname)")

        // Surface peer churn into the daemon's log — the only
        // observability surface a headless box has.
        registry.subscribe { snap in
            print("mindofagent --daemon: peers=\(snap.nodes.count)")
        }

        RunLoop.main.run() // blocks forever
        exit(0)
    }

    private static func printUsage() {
        print("""
            mindofagent — menu-bar mesh coordinator for Apple Silicon clusters

            Usage:
              mindofagent              Launch the menu-bar app (default)
              mindofagent --daemon     Headless mode — Bonjour mesh without UI
                                       (used by the LaunchDaemon for cluster nodes)
              mindofagent ifaces       Print active network interfaces and exit
              mindofagent --version    Print the version and exit
              mindofagent --help       Show this help
            """)
    }
}
