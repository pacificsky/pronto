// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pronto",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/pacificsky/angstrom.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Pronto",
            dependencies: [
                .product(name: "Angstrom", package: "angstrom"),
                .product(name: "AngstromUI", package: "angstrom")
            ],
            path: "Sources/Pronto"
        )
    ]
)
