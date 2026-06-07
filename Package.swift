// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Flightdeck",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Flightdeck",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            path: "Sources/Flightdeck"
        )
    ]
)
