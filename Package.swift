// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MUProbe",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    targets: [
        .target(
            name: "MUProbeKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mu-probe",
            dependencies: ["MUProbeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MUProbeKitTests",
            dependencies: ["MUProbeKit"],
            resources: [.copy("Audio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
