// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Minions",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Minions", targets: ["MinionsApp"]),
        .library(name: "MinionsCore", targets: ["MinionsCore"]),
    ],
    targets: [
        .target(
            name: "MinionsCore",
            path: "Sources/MinionsCore",
            resources: [.copy("Resources/models_dev_snapshot.json")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "MinionsApp",
            dependencies: ["MinionsCore"],
            path: "Sources/MinionsApp",
            resources: [
                .copy("Resources/MenuBarIcon.png"),
                .copy("Resources/MenuBarIcon@2x.png"),
                .copy("Resources/MenuBarIcon@3x.png"),
            ]
        ),
        .testTarget(
            name: "MinionsCoreTests",
            dependencies: ["MinionsCore"],
            path: "Tests/MinionsCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
