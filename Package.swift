// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jiji",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Jiji",
            path: "Sources/Jiji"
        )
    ]
)
