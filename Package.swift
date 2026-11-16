// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PinSnip",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PinSnip",
            path: "Sources/PinSnip",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
