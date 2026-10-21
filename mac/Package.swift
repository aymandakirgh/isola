// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Isola",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Isola", path: "Sources/Isola"),
        .executableTarget(name: "isolactl", path: "Sources/isolactl"),
    ],
    swiftLanguageModes: [.v5]
)
