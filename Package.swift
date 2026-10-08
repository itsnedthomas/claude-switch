// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeSwitch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeSwitch", path: "Sources/ClaudeSwitch")
    ]
)
