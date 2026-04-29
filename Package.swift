// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VidcatchMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VidcatchMac", targets: ["VidcatchMac"])
    ],
    targets: [
        .executableTarget(name: "VidcatchMac")
    ]
)
