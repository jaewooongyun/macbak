// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Macbak",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Macbak"),
        .testTarget(name: "MacbakTests", dependencies: ["Macbak"], resources: [.copy("Fixtures")]),
    ]
)
