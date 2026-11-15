// swift-tools-version:5.10
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

var products: [Product] = [
    // Cameras, streams, pan-tilt-zoom and soothing sounds, for any app: no UI.
    .library(name: "ReoBabyKit", targets: ["ReoBabyKit"]),
    // `reobaby`: the library from the command line.
    .executable(name: "reobaby", targets: ["ReoBabyCLI"]),
]

var dependencies: [Package.Dependency] = []
var kitDependencies: [Target.Dependency] = []
#if os(Linux)
// Apple platforms have CryptoKit and CommonCrypto; elsewhere their open-source twin does it.
dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.1"))
kitDependencies += [.product(name: "Crypto", package: "swift-crypto"), .product(name: "CryptoExtras", package: "swift-crypto")]
#endif

var targets: [Target] = [
    .target(name: "ReoBabyKit", dependencies: kitDependencies),
    .testTarget(name: "ReoBabyKitTests", dependencies: ["ReoBabyKit"]),
    .executableTarget(
        name: "ReoBabyCLI",
        dependencies: ["ReoBabyKit"],
        linkerSettings: [
            // The app's Info.plist inside the binary: the same identity as the app, so it reads
            // the app's settings and its keychain passwords without asking again.
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                          "-Xlinker", "\(root)/Resources/Info.plist"], .when(platforms: [.macOS])),
        ]
    ),
]

#if os(macOS)
// The Mac app. Its binary isn't called ReoBaby here: on a case-insensitive disk that would be the
// same file as `reobaby`. `make app` puts it in the bundle as ReoBaby.
targets.append(.executableTarget(name: "ReoBabyApp", dependencies: ["ReoBabyKit"]))
#endif

let package = Package(
    name: "ReoBaby",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
