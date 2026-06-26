// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pronto",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Pronto",
            path: "Sources/Pronto"
        )
    ]
)
