// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "T3Island",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "T3Island",
            path: "Sources/T3Island",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
