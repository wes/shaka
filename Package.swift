// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shaka",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Shaka",
            path: "Sources/Shaka"
        )
    ]
)
