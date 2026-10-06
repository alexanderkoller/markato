// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AstraMarkdown",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "AstraMarkdown", targets: ["AstraMarkdown"])],
    dependencies: [],
    targets: [
        .target(name: "MarkdownCore", resources: [.process("Resources")]),
        .executableTarget(name: "AstraMarkdown", dependencies: [
            "MarkdownCore"
        ]),
        .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"])
    ],
    swiftLanguageModes: [.v5]
)
