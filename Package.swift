// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JHCutStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "JHCutStudio", targets: ["JHCutStudio"]), .executable(name: "JHCutValidate", targets: ["JHCutValidate"])],
    targets: [
        .target(name: "JHCutCore", path: ".", sources: ["Domain", "MediaEngine", "Persistence", "Services"]),
        .executableTarget(name: "JHCutStudio", dependencies: ["JHCutCore"], path: "App"),
        .executableTarget(name: "JHCutValidate", dependencies: ["JHCutCore"], path: "Validation"),
        .testTarget(name: "JHCutCoreTests", dependencies: ["JHCutCore"], path: "Tests", sources: ["DomainTests.swift", "UpgradeTests.swift", "PersistenceTests.swift"])
    ],
    swiftLanguageModes: [.v5]
)
