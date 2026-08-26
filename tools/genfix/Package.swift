// swift-tools-version: 5.9
import PackageDescription

// A tiny executable that prints spec/pairing/pairing-fixtures.json.
// Separate from the main package so generating fixtures never becomes a build
// dependency of shipping the app.
let package = Package(
    name: "genfix",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "MozzKit", path: "../..")],
    targets: [
        .executableTarget(
            name: "genfix",
            dependencies: [.product(name: "MozzPairing", package: "MozzKit")])
    ])
