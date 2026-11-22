// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Macbak",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Macbak",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            // scripts/build-app.sh puts Sparkle.framework in Contents/Frameworks, next to Contents/MacOS.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MacbakTests", dependencies: ["Macbak"], resources: [.copy("Fixtures")]),
    ]
)
