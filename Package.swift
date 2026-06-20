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
            path: "Sources/Jiji",
            // The Resources/ folder is bundled into Jiji.app by build-app.sh,
            // not by SPM — that way the executable doesn't depend on the
            // SPM-generated Bundle.module (which requires non-empty
            // processed resources to be synthesised).
            exclude: ["Resources"]
        )
    ]
)
