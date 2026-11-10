// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-henshin",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "Henshin",
            targets: ["Henshin"]
        ),
        .library(
            name: "HenshinAnalysis",
            targets: ["HenshinAnalysis"]
        ),
        .library(
            name: "HenshinStateSpace",
            targets: ["HenshinStateSpace"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
        .package(url: "https://github.com/mipalgu/swift-ecore", exact: "0.8.0"),
        .package(url: "https://github.com/mipalgu/swift-aql", exact: "0.8.0"),
    ],
    targets: [
        .target(
            name: "Henshin",
            dependencies: [
                .product(name: "ECore", package: "swift-ecore"),
                .product(name: "EMFBase", package: "swift-ecore"),
                .product(name: "AQL", package: "swift-aql"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "HenshinAnalysis",
            dependencies: [
                "Henshin",
                .product(name: "ECore", package: "swift-ecore"),
                .product(name: "EMFBase", package: "swift-ecore"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "HenshinStateSpace",
            dependencies: [
                "Henshin",
                .product(name: "ECore", package: "swift-ecore"),
                .product(name: "EMFBase", package: "swift-ecore"),
                .product(name: "AQL", package: "swift-aql"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "HenshinTests",
            dependencies: [
                "Henshin",
                .product(name: "ECore", package: "swift-ecore"),
                .product(name: "EMFBase", package: "swift-ecore"),
            ],
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "HenshinAnalysisTests",
            dependencies: [
                "HenshinAnalysis",
                "Henshin",
                .product(name: "ECore", package: "swift-ecore"),
                .product(name: "EMFBase", package: "swift-ecore"),
            ],
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "HenshinStateSpaceTests",
            dependencies: [
                "HenshinStateSpace",
                "Henshin",
                .product(name: "ECore", package: "swift-ecore"),
                .product(name: "EMFBase", package: "swift-ecore"),
            ],
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
    ]
)
