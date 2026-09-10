// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PopcornHUD",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PopcornHUD", targets: ["PopcornHUD"]),
        .executable(name: "voxtype-clean", targets: ["VoxtypeClean"]),
        .executable(name: "PopcornCapture", targets: ["PopcornCapture"]),
    ],
    targets: [
        .target(name: "PopcornCore", path: "Sources/PopcornCore"),
        .target(
            name: "PopcornArt",
            dependencies: ["PopcornCore"],
            path: "Sources/PopcornArt"
        ),
        .executableTarget(
            name: "PopcornHUD",
            dependencies: ["PopcornCore", "PopcornArt"],
            path: "Sources/PopcornHUD"
        ),
        .executableTarget(
            name: "VoxtypeClean",
            dependencies: ["PopcornCore"],
            path: "Sources/VoxtypeClean"
        ),
        .executableTarget(
            name: "PopcornCapture",
            dependencies: ["PopcornCore", "PopcornArt"],
            path: "Sources/PopcornCapture"
        ),
        .testTarget(
            name: "PopcornCoreTests",
            dependencies: ["PopcornCore"],
            path: "Tests/PopcornCoreTests"
        ),
    ]
)
