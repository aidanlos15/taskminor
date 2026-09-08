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
            path: "Sources/Availeth",
            swiftSettings: [
                // Keep the shipped binary from carrying build-machine paths.
                // Without this the developer's home directory is embedded in it.
                .unsafeFlags(["-Xfrontend", "-debug-prefix-map", "-Xfrontend", "\(Context.packageDirectory)=."],
                             .when(configuration: .release)),
            ],
            linkerSettings: [
                // -x removes local symbols; the release package strips the rest.
                .unsafeFlags(["-Xlinker", "-x"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "AvailethTests",
            dependencies: ["Availeth"],
            path: "Tests/AvailethTests"
        ),
    ]
)
