// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MindOfAgent",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MindOfAgent", targets: ["MindOfAgent"]),
        .library(name: "MindOfAgentCore", targets: ["MindOfAgentCore"]),
    ],
    targets: [
        .executableTarget(
            name: "MindOfAgent",
            dependencies: ["MindOfAgentCore"]
        ),
        .target(
            name: "MindOfAgentCore"
        ),
        .testTarget(
            name: "MindOfAgentCoreTests",
            dependencies: ["MindOfAgentCore"]
        ),
    ]
)
