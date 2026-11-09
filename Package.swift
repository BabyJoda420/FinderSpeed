// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FinderSpeed",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FinderSpeed",
            path: "Sources/FinderSpeed",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FinderSpeedTests",
            dependencies: ["FinderSpeed"],
            path: "Tests/FinderSpeedTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
