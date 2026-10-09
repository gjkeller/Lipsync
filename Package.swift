// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lipsync",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "Lipsync", targets: ["Lipsync"]),
    ],
    targets: [
        // Pure logic: models, song matching and the sync engine. No AppKit, MusicKit or
        // Core Audio, so the whole thing runs under `swift test` against simulated players.
        .target(name: "LipsyncCore"),
        .executableTarget(
            name: "Lipsync",
            dependencies: ["LipsyncCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("MusicKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(name: "LipsyncCoreTests", dependencies: ["LipsyncCore"]),
    ]
)
