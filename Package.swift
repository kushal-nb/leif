// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Leif",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Leif",
            path: "Sources/Leif"
        )
    ]
)
