// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlitzCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "BlitzCore", targets: ["BlitzCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "BlitzCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "blitzctl",
            dependencies: ["BlitzCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BlitzSynthetic",
            dependencies: ["BlitzCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // A pretend Gmail for benchmarks and tests. Not part of the library the apps link.
        .target(
            name: "BlitzFake",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "blitzbench",
            dependencies: ["BlitzCore", "BlitzSynthetic", "BlitzFake"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BlitzCoreTests",
            dependencies: ["BlitzCore", "BlitzFake"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
