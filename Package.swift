// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Berth",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CBerthCore"),
        .executableTarget(name: "Berth", dependencies: ["CBerthCore"]),
    ]
)
