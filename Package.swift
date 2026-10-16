// swift-tools-version: 6.0
import Foundation
import PackageDescription

let vendoredUltralightSDK = Context.packageDirectory + "/Vendor/Ultralight"
let ultralightSDK = ProcessInfo.processInfo.environment["ASTRA_ULTRALIGHT_SDK"] ?? vendoredUltralightSDK

let package = Package(
    name: "Markato",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Markato", targets: ["Markato"]),
        .executable(name: "MarkatoPrintRenderer", targets: ["MarkatoPrintRenderer"]),
        .executable(name: "HTMLPreviewHarness", targets: ["HTMLPreviewHarness"])
    ],
    dependencies: [],
    targets: [
        .target(name: "CComrak", linkerSettings: [
            .unsafeFlags([Context.packageDirectory + "/.build/comrak/release/libastra_comrak.a"])
        ]),
        .target(name: "MarkdownCore", dependencies: ["CComrak"], resources: [.process("Resources")]),
        .target(name: "CUltralightPreview",
            cxxSettings: [.unsafeFlags(["-std=c++20", "-I", ultralightSDK + "/include"])],
            linkerSettings: [
                .unsafeFlags(["-L", ultralightSDK + "/bin", "-Xlinker", "-rpath", "-Xlinker", ultralightSDK + "/bin", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedLibrary("UltralightCore"), .linkedLibrary("Ultralight"),
                .linkedLibrary("WebCore"), .linkedLibrary("AppCore")
            ]),
        .target(name: "HTMLPreview", dependencies: ["CUltralightPreview", "MarkdownCore"],
            resources: [.process("Resources")]),
        .executableTarget(name: "Markato", dependencies: [
            "MarkdownCore", "HTMLPreview"
        ]),
        .executableTarget(name: "HTMLPreviewHarness", dependencies: ["HTMLPreview", "MarkdownCore"]),
        .executableTarget(name: "MarkatoPrintRenderer"),
        .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"]),
        .testTarget(name: "HTMLPreviewTests", dependencies: ["HTMLPreview"])
    ],
    swiftLanguageModes: [.v5]
)
