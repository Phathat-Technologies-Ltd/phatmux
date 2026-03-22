// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "phatmux",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "phatmux", targets: ["phatmux"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "phatmux",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        )
    ]
)
