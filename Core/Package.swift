// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MachCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "MachCore", targets: ["MachCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "MachCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "machctl",
            dependencies: ["MachCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MachSynthetic",
            dependencies: ["MachCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // A pretend Gmail for benchmarks and tests. Not part of the library the apps link.
        .target(
            name: "MachFake",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "machbench",
            dependencies: ["MachCore", "MachSynthetic", "MachFake"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MachCoreTests",
            dependencies: ["MachCore", "MachFake"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
