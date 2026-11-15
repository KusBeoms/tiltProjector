// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TiltProjector",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TiltProjector",
            path: "Sources/TiltProjector"
        )
    ]
)
