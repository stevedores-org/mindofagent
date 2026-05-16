# MindOfAgent

Menu-bar Mac app for coordinating an Apple Silicon AI inference cluster.

MindOfAgent advertises and discovers peer Macs over Bonjour (`_mindofagent._tcp`) using Apple's `Network` framework. When two or more Macs share a subnet — typically connecting them with a Thunderbolt cable so macOS brings up the Thunderbolt Bridge interface — they find each other automatically, with no manual IP configuration, and surface in each other's menu bar.

It is intentionally a **mesh, not a controller/agent**: every node both advertises *and* browses. No central coordinator, no single point of failure, no bootstrap config. Pause one, the others keep talking.

The roadmap (hardware profile, telemetry, optional controller registration, daemon mode, `.pkg` packaging) is tracked in the [`v1.0-cheat-codes-integration`](https://github.com/stevedores-org/mindofagent/milestone/2) milestone. The current scope is [`v0-mesh-foundation`](https://github.com/stevedores-org/mindofagent/milestone/1) — discovery + node list + persistence.

## Requirements

- **macOS 13** (Ventura) or later — required for `MenuBarExtra`.
- **Swift 5.9+** toolchain. Either the Command Line Tools (`xcode-select --install`, sufficient for `swift build`/`swift run`) or full Xcode (required for `swift test`, since the macOS CLT toolchain does not bundle `XCTest`).

## Build & run

```sh
git clone https://github.com/stevedores-org/mindofagent.git
cd mindofagent
swift build
swift run MindOfAgent
```

A network icon will appear in the menu bar. Click it for the peer list. The first launch shows "No peers" until a second instance on the same subnet is up. If you have a Thunderbolt cable between two Macs, plug it in and run `swift run MindOfAgent` on both — they should find each other within a few seconds.

## Architecture

```
┌─────────────────────────┐         ┌─────────────────────────┐
│  Mac A — MenuBarExtra   │         │  Mac B — MenuBarExtra   │
│  ┌─────────────────┐    │         │    ┌─────────────────┐  │
│  │ NWListener      │◄───┼─────────┼────│  NWBrowser      │  │
│  │ advertises      │    │ Bonjour │    │  observes peers │  │
│  └─────────────────┘    │ over    │    └─────────────────┘  │
│  ┌─────────────────┐    │ TB      │    ┌─────────────────┐  │
│  │ NWBrowser       │────┼─────────┼───►│  NWListener     │  │
│  │ observes peers  │    │ Bridge  │    │  advertises     │  │
│  └─────────────────┘    │ subnet  │    └─────────────────┘  │
│         │               │         │             │           │
│         ▼               │         │             ▼           │
│  ┌─────────────────┐    │         │    ┌─────────────────┐  │
│  │ NodeRegistry    │    │         │    │  NodeRegistry   │  │
│  └─────────────────┘    │         │    └─────────────────┘  │
└─────────────────────────┘         └─────────────────────────┘
```

Layout:

- `Sources/MindOfAgentCore/` — testable mesh logic. `Node` value type, thread-safe `NodeRegistry`, Bonjour-driven `Discovery`. No UI.
- `Sources/MindOfAgent/` — `@main` SwiftUI app with the `MenuBarExtra` scene and an `AppCoordinator` that owns the `Discovery` instance.
- `Tests/MindOfAgentCoreTests/` — XCTest coverage of the registry contract.

## Auto-launch (planned)

The full LaunchAgent install + reboot resume story is tracked in [#9](https://github.com/stevedores-org/mindofagent/issues/9). For v0 you run the app manually with `swift run MindOfAgent`. When #9 lands, expect:

```sh
make install-launch-agent   # builds release binary + installs ~/Library/LaunchAgents plist
```

For headless cluster nodes (no GUI session), a separate LaunchDaemon mode is in [#16](https://github.com/stevedores-org/mindofagent/issues/16).

## Project status

Pre-1.0. Tracked in the [v0 epic (#1)](https://github.com/stevedores-org/mindofagent/issues/1).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
