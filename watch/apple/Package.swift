// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VanguardApple",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "VanguardApple", targets: ["VanguardApple"])],
    targets: [
        .binaryTarget(name: "llama", path: ".native/llama.xcframework"),
        .target(name: "VanguardApple", dependencies: ["llama"], resources: [.process("Migrations")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "VanguardAppleTests", dependencies: ["VanguardApple"])
    ]
)
