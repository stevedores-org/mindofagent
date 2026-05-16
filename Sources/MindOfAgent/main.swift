// Placeholder entry point. Replaced by the SwiftUI `@main` App in issue #4
// (MenuBarExtra). Kept minimal so `swift build` succeeds against the v0
// scaffold while the UI lands separately.

import Foundation
import MindOfAgentCore

let hostname = Host.current().localizedName ?? "mac-node"
print("MindOfAgent placeholder — \(hostname). SwiftUI MenuBarExtra app lands in #4.")
