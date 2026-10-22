// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OBDReader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OBDReader",
            path: "Sources/OBDReader"
        )
    ]
)
