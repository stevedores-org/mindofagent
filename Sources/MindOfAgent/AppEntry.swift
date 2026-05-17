import Foundation
import MindOfAgentCore

/// Process entry point. Inspects `CommandLine.arguments` for CLI subcommands
/// before falling through to the SwiftUI app, so debugging from a terminal
/// (`mindofagent ifaces`) doesn't require launching the menu-bar UI.
@main
enum AppEntry {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 2 {
            switch args[1] {
            case "ifaces":
                runIfacesSubcommand()
                exit(0)
            case "--help", "-h", "help":
                printUsage()
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown subcommand: \(args[1])\n".utf8))
                printUsage()
                exit(64) // EX_USAGE
            }
        }
        MindOfAgentApp.main()
    }

    private static func runIfacesSubcommand() {
        for iface in NetworkManager.interfaces() {
            print(iface.summary)
        }
    }

    private static func printUsage() {
        print("""
            mindofagent — menu-bar mesh coordinator for Apple Silicon clusters

            Usage:
              mindofagent              Launch the menu-bar app (default)
              mindofagent ifaces       Print active network interfaces and exit
              mindofagent --help       Show this help
            """)
    }
}
