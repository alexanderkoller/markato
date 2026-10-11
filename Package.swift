// swift-tools-version: 6.0
import Foundation
import PackageDescription

let vendoredUltralightSDK = Context.packageDirectory + "/Vendor/Ultralight"
let experimentUltralightSDK = Context.packageDirectory + "/research/2026-10-11/html-renderer-benchmark/third_party/ultralight"
let defaultUltralightSDK = FileManager.default.fileExists(atPath:vendoredUltralightSDK + "/include")
    ? vendoredUltralightSDK : experimentUltralightSDK
let ultralightSDK = ProcessInfo.processInfo.environment["ASTRA_ULTRALIGHT_SDK"] ?? defaultUltralightSDK

let package = Package(
    name: "AstraMarkdown",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "AstraMarkdown", targets: ["AstraMarkdown"])],
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
        .executableTarget(name: "AstraMarkdown", dependencies: [
            "MarkdownCore", "HTMLPreview"
        ]),
        .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"])
    ],
    swiftLanguageModes: [.v5]
)
