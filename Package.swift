// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "IPInformer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "IPInformer", targets: ["IPInformer"]),
        .executable(name: "IPInformerUpdater", targets: ["IPInformerUpdater"])
    ],
    targets: [
        .executableTarget(
            name: "IPInformer",
            path: "Sources/IPInformer",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "IPInformerUpdater",
            path: "Sources/IPInformerUpdater"
        ),
        .testTarget(
            name: "IPInformerTests",
            dependencies: ["IPInformer"],
            path: "Tests/IPInformerTests"
        )
    ]
)
