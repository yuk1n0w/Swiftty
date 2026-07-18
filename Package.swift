// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Swiftty",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Swiftty", targets: ["Swiftty"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.14.0")
    ],
    targets: [
        .executableTarget(
            name: "Swiftty",
            dependencies: ["SwiftTerm"]
        )
    ],
    swiftLanguageModes: [.v6]
)
