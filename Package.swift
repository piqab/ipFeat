// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ipFeat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ipFeat", targets: ["ipFeat"]),
        .executable(name: "ipFeatUpdater", targets: ["ipFeatUpdater"])
    ],
    targets: [
        .executableTarget(
            name: "ipFeat",
            path: "Sources/ipFeat",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "ipFeatUpdater",
            path: "Sources/ipFeatUpdater"
        ),
        .testTarget(
            name: "ipFeatTests",
            dependencies: ["ipFeat"],
            path: "Tests/ipFeatTests"
        )
    ]
)
