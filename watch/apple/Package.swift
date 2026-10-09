// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VanguardApple",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "VanguardApple", targets: ["VanguardApple"]),
               // Development host: the real Watch screens and pipeline in a Mac window. Not a shipping app.
               .executable(name: "VanguardWatchMac", targets: ["VanguardWatchMac"])],
    targets: [
        .binaryTarget(name: "llama", path: ".native/llama.xcframework"),
        .binaryTarget(name: "whisper", path: ".native/whisper.xcframework"),
        .target(name: "VanguardApple", dependencies: ["llama", .target(name: "whisper", condition: .when(platforms: [.watchOS]))], resources: [.process("Migrations"), .copy("Resources/medical_terms.json"), .copy("Resources/observation-phrases.json")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "VanguardWatchMac", dependencies: ["VanguardApple"], path: "Sources/VanguardWatchMac",
            exclude: ["Info.plist"],
            // Embeds usage descriptions so macOS can ask for the microphone and speech permissions.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/VanguardWatchMac/Info.plist"])]),
        .testTarget(name: "VanguardAppleTests", dependencies: ["VanguardApple"])
    ]
)
