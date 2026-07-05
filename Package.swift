// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KirtanSplitter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "KirtanSplitter", targets: ["KirtanSplitterApp"])
    ],
    targets: [
        .executableTarget(
            name: "KirtanSplitterApp",
            path: "Sources/KirtanSplitterApp"
        )
    ]
)
