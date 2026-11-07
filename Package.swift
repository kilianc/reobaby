// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ReoBaby",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ReoBaby", path: "Sources/ReoBaby")
    ]
)
