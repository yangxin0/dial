// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dial",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Dial",
            path: "Sources/Dial",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
