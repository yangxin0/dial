// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dial",
    platforms: [.macOS(.v13)],
    targets: [
        // The ring's maths and the wheel event: no UI, so it can be tested.
        .target(name: "DialKit", path: "Sources/DialKit"),
        .executableTarget(
            name: "Dial",
            dependencies: ["DialKit"],
            path: "Sources/Dial",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        // make test-scroll: drags the real ring over real apps.
        .executableTarget(
            name: "ScrollTest",
            dependencies: ["DialKit"],
            path: "Sources/ScrollTest",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "DialKitTests", dependencies: ["DialKit"], path: "Tests/DialKitTests"),
    ]
)
