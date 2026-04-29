// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacVidCatch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacVidCatch", targets: ["MacVidCatch"])
    ],
    targets: [
        .executableTarget(name: "MacVidCatch")
    ]
)
