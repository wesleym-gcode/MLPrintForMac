// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MLPrint",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CSpl",
            linkerSettings: [.linkedLibrary("cups")]
        ),
        .executableTarget(
            name: "MLPrint",
            dependencies: ["CSpl"]
        ),
    ]
)
