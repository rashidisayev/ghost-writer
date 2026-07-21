// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhostWriter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GhostWriter", targets: ["GhostWriter"]),
    ],
    targets: [
        .target(name: "GhostWriterCore"),
        .target(name: "GhostWriterStorage", dependencies: ["GhostWriterCore"]),
        .target(name: "GhostWriterAccessibility", dependencies: ["GhostWriterCore"]),
        .target(name: "GhostWriterAI", dependencies: ["GhostWriterCore", "GhostWriterStorage"]),
        .target(name: "GhostWriterInput"),
        .target(
            name: "GhostWriterUI",
            dependencies: ["GhostWriterCore", "GhostWriterStorage", "GhostWriterAccessibility", "GhostWriterAI", "GhostWriterInput"]
        ),
        .executableTarget(
            name: "GhostWriter",
            dependencies: ["GhostWriterCore", "GhostWriterStorage", "GhostWriterAccessibility", "GhostWriterAI", "GhostWriterInput", "GhostWriterUI"]
        ),
        .testTarget(name: "GhostWriterCoreTests", dependencies: ["GhostWriterCore"]),
        .testTarget(
            name: "GhostWriterAccessibilityTests",
            dependencies: ["GhostWriterAccessibility"]
        ),
    ]
)
