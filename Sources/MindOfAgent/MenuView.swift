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
            thunderboltStatus
            controllerStatus
            Divider()
            footer
        }
        .padding(10)
        .frame(minWidth: 260)
    }

    /// Surfaces the controller-registration status when a controllerURL
    /// is configured. Hidden entirely in mesh-only mode (the v0 default)
    /// — no row at all, not even a "not configured" line, to keep the
    /// menu tight for users who don't use a controller.
    @ViewBuilder
    private var controllerStatus: some View {
        // Bind to locals so SwiftUI's ViewBuilder doesn't trip over the
        // mix of `||` and `@Published` access on a @MainActor coordinator.
        let registeredAt = coordinator.lastRegistrationAt
        let statusError = coordinator.lastRegistrationStatus
        if registeredAt != nil || statusError != nil {
            HStack(spacing: 6) {
                if statusError != nil {
                    Image(systemName: "exclamationmark.cloud")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let at = registeredAt {
                        Text("Controller registered \(Self.timeFormatter.string(from: at))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let err = statusError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    /// One-line summary of the Thunderbolt bridge state. Mirrors what
    /// System Settings → Network shows, plus the peer count from our
    /// own registry so the user can see "Thunderbolt up, peers showing"
    /// vs "Thunderbolt up, no peers — other node not running" at a glance.
    @ViewBuilder
    private var thunderboltStatus: some View {
        if let tb = coordinator.thunderboltBridge {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Thunderbolt: \(tb.name)")
                        .font(.callout)
                    if let v4 = tb.ipv4.first {
                        Text(v4)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        } else {
            HStack {
                Image(systemName: "bolt.slash")
                    .foregroundStyle(.secondary)
                Text("Thunderbolt: not connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Cluster peers")
                .font(.headline)
            if coordinator.paused {
                Text("· paused")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
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
        VStack(alignment: .leading, spacing: 4) {
            Button(coordinator.paused ? "Resume Discovery" : "Pause Discovery") {
                coordinator.togglePause()
            }
            // Pausing only makes sense if Discovery is actually running. When
            // startup failed (`startupError != nil`), the listener/browser
            // were never live — disabling the button avoids the confusing
            // three-indicator state (red error + orange paused tag + slash
            // icon) flagged in the PR #23 review.
            .disabled(coordinator.startupError != nil)
            .keyboardShortcut("p")

            Button("Quit MindOfAgent") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
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
