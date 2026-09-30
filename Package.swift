// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Daystar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Daystar", targets: ["APODWallpaperApp"])
    ],
    targets: [
        .target(
            name: "APODWallpaperCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "APODWallpaperApp",
            dependencies: ["APODWallpaperCore"]
        ),
        .testTarget(
            name: "APODWallpaperCoreTests",
            dependencies: ["APODWallpaperCore"]
        )
    ]
)
