// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lekora",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Lekora",
            targets: ["Lekora"]
        ),
    ],
    targets: [
        .target(
            name: "Lekora",
            path: "Lekora"
        ),
        .testTarget(
            name: "LekoraTests",
            dependencies: ["Lekora"],
            path: "LekoraTests"
        ),
    ]
)
