// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FluxDownload",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FluxDownload", targets: ["FluxDownloadApp"]),
        .executable(name: "FluxDownloadNativeHost", targets: ["FluxDownloadNativeHost"]),
        .executable(name: "fluxdownload-cli", targets: ["FluxDownloadCLI"]),
        .library(name: "FluxDownloadCore", targets: ["FluxDownloadCore"]),
        .library(name: "FluxDownloadEngine", targets: ["FluxDownloadEngine"]),
        .executable(name: "FluxDownloadTestRunner", targets: ["FluxDownloadTestRunner"]),
    ],
    targets: [
        .target(
            name: "FluxDownloadCore",
            path: "Sources/FluxDownloadCore"
        ),
        .target(
            name: "FluxDownloadBrowserProtocol",
            dependencies: ["FluxDownloadCore"],
            path: "Sources/FluxDownloadBrowserProtocol"
        ),
        .target(
            name: "FluxDownloadPersistence",
            dependencies: ["FluxDownloadCore"],
            path: "Sources/FluxDownloadPersistence",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "FluxDownloadEngine",
            dependencies: ["FluxDownloadCore", "FluxDownloadPersistence"],
            path: "Sources/FluxDownloadEngine",
            linkerSettings: [
                .linkedFramework("Network")
            ]
        ),
        .target(
            name: "FluxDownloadScheduler",
            dependencies: ["FluxDownloadCore", "FluxDownloadPersistence", "FluxDownloadEngine"],
            path: "Sources/FluxDownloadScheduler"
        ),
        .target(
            name: "FluxDownloadMedia",
            dependencies: ["FluxDownloadCore"],
            path: "Sources/FluxDownloadMedia"
        ),
        .target(
            name: "FluxDownloadGrabber",
            dependencies: ["FluxDownloadCore"],
            path: "Sources/FluxDownloadGrabber",
            linkerSettings: [
                .linkedFramework("Network")
            ]
        ),
        .target(
            name: "FluxDownloadIPC",
            dependencies: ["FluxDownloadCore", "FluxDownloadBrowserProtocol"],
            path: "Sources/FluxDownloadIPC"
        ),
        .target(
            name: "FluxDownloadTestServer",
            dependencies: ["FluxDownloadCore"],
            path: "Sources/FluxDownloadTestServer",
            linkerSettings: [
                .linkedFramework("Network")
            ]
        ),
        .executableTarget(
            name: "FluxDownloadNativeHost",
            dependencies: ["FluxDownloadIPC", "FluxDownloadBrowserProtocol", "FluxDownloadCore"],
            path: "Sources/FluxDownloadNativeHost",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "FluxDownloadCLI",
            dependencies: ["FluxDownloadIPC", "FluxDownloadBrowserProtocol", "FluxDownloadCore"],
            path: "Sources/FluxDownloadCLI"
        ),
        .executableTarget(
            name: "FluxDownloadApp",
            dependencies: [
                "FluxDownloadCore",
                "FluxDownloadBrowserProtocol",
                "FluxDownloadPersistence",
                "FluxDownloadEngine",
                "FluxDownloadScheduler",
                "FluxDownloadMedia",
                "FluxDownloadGrabber",
                "FluxDownloadIPC"
            ],
            path: "Sources/FluxDownloadApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "FluxDownloadTestRunner",
            dependencies: [
                "FluxDownloadCore",
                "FluxDownloadBrowserProtocol",
                "FluxDownloadPersistence",
                "FluxDownloadEngine",
                "FluxDownloadScheduler",
                "FluxDownloadMedia",
                "FluxDownloadGrabber",
                "FluxDownloadIPC",
                "FluxDownloadTestServer"
            ],
            path: "Sources/FluxDownloadTestRunner"
        )
    ]
)
