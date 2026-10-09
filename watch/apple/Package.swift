// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VanguardApple",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "VanguardApple", targets: ["VanguardApple"])],
    targets: [
        .target(name: "VanguardApple"),
        .testTarget(name: "VanguardAppleTests", dependencies: ["VanguardApple"])
    ]
)
