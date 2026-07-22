// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AndroidFileBrowser",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AndroidFileBrowser", targets: ["AndroidFileBrowser"])
    ],
    dependencies: [
        .package(path: "Vendor/MTPKit")
    ],
    targets: [
        .executableTarget(
            name: "AndroidFileBrowser",
            dependencies: ["AndroidFileBrowserCore"],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .target(
            name: "AndroidFileBrowserCore",
            dependencies: [
                .product(name: "MTPKit", package: "MTPKit")
            ]
        ),
        .testTarget(
            name: "AndroidFileBrowserCoreTests",
            dependencies: ["AndroidFileBrowserCore"]
        )
    ]
)
