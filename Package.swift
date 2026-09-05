// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Availeth",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Availeth",
            path: "Sources/Availeth"
        ),
        .testTarget(
            name: "AvailethTests",
            dependencies: ["Availeth"],
            path: "Tests/AvailethTests"
        ),
    ]
)
