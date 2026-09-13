// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "DBCenter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DBCenter", targets: ["DBCenter"])],
    targets: [
        .target(name: "CDBDrivers", linkerSettings: [.linkedLibrary("dl")]),
        .executableTarget(name: "DBCenter", dependencies: ["CDBDrivers"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DBCenterTests", dependencies: ["DBCenter"])
    ]
)
