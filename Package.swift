// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMessenger",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacMessenger", targets: ["MacMessenger"])
    ],
    targets: [
        .executableTarget(
            name: "MacMessenger",
            path: "Sources/MacMessenger",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
