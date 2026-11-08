// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lekora",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0")
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
