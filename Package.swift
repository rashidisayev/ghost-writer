// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quill",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Quill", targets: ["Quill"]),
    ],
    targets: [
        .target(name: "QuillCore"),
        .target(name: "QuillStorage", dependencies: ["QuillCore"]),
        .target(name: "QuillAccessibility", dependencies: ["QuillCore"]),
        .target(name: "QuillAI", dependencies: ["QuillCore", "QuillStorage"]),
        .target(name: "QuillInput"),
        .target(
            name: "QuillUI",
            dependencies: ["QuillCore", "QuillStorage", "QuillAccessibility", "QuillAI", "QuillInput"]
        ),
        .executableTarget(
            name: "Quill",
            dependencies: ["QuillCore", "QuillStorage", "QuillAccessibility", "QuillAI", "QuillInput", "QuillUI"]
        ),
        .testTarget(name: "QuillCoreTests", dependencies: ["QuillCore"]),
    ]
)
