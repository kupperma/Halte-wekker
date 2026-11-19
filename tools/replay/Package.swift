// swift-tools-version:5.9
// The replay tool: real exported rides (log lines and GPS points) through the app's own on-board matcher, scored.
// Sources/replay/App holds links to the app's pure matcher files (the same ones the unit tests compile), so it always
// runs the matcher as it is in ios/App. See docs/logs-export.md.
//
//   swift run -c release replay fixtures/synthetic.json
//   swift test
import PackageDescription

let package = Package(
    name: "replay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "replay", path: "Sources/replay"),
        .testTarget(name: "ReplayTests", dependencies: ["replay"], path: "Tests/ReplayTests"),
    ]
)
