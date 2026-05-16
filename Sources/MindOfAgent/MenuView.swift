import SwiftUI
import AppKit
import MindOfAgentCore

struct MenuView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            peerList
            Divider()
            footer
        }
        .padding(10)
        .frame(minWidth: 260)
    }

    private var header: some View {
        HStack {
            Text("Cluster peers")
                .font(.headline)
            Spacer()
            Text("\(coordinator.snapshot.nodes.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var peerList: some View {
        if let error = coordinator.startupError {
            Text(error)
                .foregroundStyle(.red)
                .font(.callout)
        } else if coordinator.snapshot.nodes.isEmpty {
            Text("No peers — bring up a Thunderbolt bridge or run a second node on the LAN.")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else {
            ForEach(coordinator.snapshot.nodes) { node in
                NodeRow(node: node)
            }
        }
    }

    private var footer: some View {
        Button("Quit MindOfAgent") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private struct NodeRow: View {
    let node: Node

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayName)
                if !node.host.isEmpty {
                    Text(node.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let mem = node.memoryGB {
                Text("\(mem) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
