// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AuraSplitter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AuraSplitter", targets: ["AuraSplitterApp"])
    ],
    targets: [
        .executableTarget(
            name: "AuraSplitterApp",
            path: "Sources/AuraSplitterApp"
        ),
        .testTarget(
            name: "AuraSplitterAppTests",
            dependencies: ["AuraSplitterApp"],
            path: "tests/AuraSplitterAppTests"
        )
    ]
)
