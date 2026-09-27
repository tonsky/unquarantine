// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Unquarantine",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Unquarantine", targets: ["Unquarantine"])],
    targets: [
        .target(name: "UnquarantineCore"),
        .executableTarget(name: "Unquarantine", dependencies: ["UnquarantineCore"]),
        .testTarget(name: "UnquarantineCoreTests", dependencies: ["UnquarantineCore"]),
    ]
)
