import Foundation
import HTMLPreview
import Testing

@Test func completeHTMLContainsOrderedBlocksStylesAndSafetyPolicy() {
    let html=HTMLDocument.render(title:"A < B & \"C\"",fragments:["<h1>First</h1>","<p>Second</p>"])
    #expect(html.contains("<title>A &lt; B &amp; &quot;C&quot;</title>"))
    #expect(html.contains("Content-Security-Policy"))
    #expect(html.contains("default-src 'none'"))
    #expect(html.contains("@media print"))
    #expect(html.contains("@page { size: A4 portrait; margin: 15mm; }"))
    #expect(html.contains("font-size: 11pt"))
    #expect(html.contains("table, tr, img"))
    #expect(html.contains("max-height: 267mm"))
    #expect(html.contains(".katex"))
    #expect(html.range(of:"<h1>First</h1>")!.lowerBound < html.range(of:"<p>Second</p>")!.lowerBound)
    #expect(html.contains("<section class=\"astra-preview-block document-first\"><h1>First</h1></section>"))
    #expect(html.contains("<section class=\"astra-preview-block\"><p>Second</p></section>"))
    #expect(!html.contains("last-block"))
}

@Test func localImagesUseTheirAbsoluteFileURL() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:directory)}
    try Data([0x89,0x50,0x4e,0x47]).write(to:directory.appendingPathComponent("image.png"))
    let fragment="<img src=\"astra-asset://image/?source=image.png\">"
    let html=HTMLDocument.render(title:"Image",fragments:[fragment],baseURL:directory)
    #expect(html.contains("src=\"\(directory.appendingPathComponent("image.png").absoluteString)\""))
    #expect(!html.contains("src=\"data:"))
    #expect(!html.contains("astra-asset:"))
}

@Test func remoteImagesRemainRemote() {
    let fragment="<img src=\"astra-asset://image/?source=https%3A%2F%2Fexample.com%2Fimage.png\">"
    let html=HTMLDocument.render(title:"Remote",fragments:[fragment])
    #expect(html.contains("src=\"https://example.com/image.png\""))
}

@Test func imageLoadingCanBeDeferredWithoutLosingItsResolvedSource() {
    let prepared=HTMLAssetPreparer(delayImages:true).prepare(
        "<img src=\"astra-asset://image/?source=image.png\" alt=\"image\">",
        baseURL:URL(fileURLWithPath:"/tmp/document",isDirectory:true))
    #expect(prepared.contains("src=\"\""))
    #expect(prepared.contains("data-astra-delayed-src=\"file:///tmp/document/image.png\""))

    let direct=HTMLAssetPreparer(delayImages:true).prepare(
        "<img src=\"https://example.com/slow.png\">",baseURL:nil)
    #expect(direct.contains("src=\"\""))
    #expect(direct.contains("data-astra-delayed-src=\"https://example.com/slow.png\""))
}

@Test func localImageMetadataReservesIntrinsicGeometry() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:directory)}
    let svg=directory.appendingPathComponent("diagram.svg")
    try "<svg viewBox=\"0 0 640 360\"></svg>".write(to:svg,atomically:true,encoding:.utf8)
    let prepared=HTMLAssetPreparer().prepare(
        "<img src=\"astra-asset://image/?source=diagram.svg\">",baseURL:directory)
    #expect(prepared.contains("src=\"\(svg.absoluteString)\""))
    #expect(prepared.contains("width=\"640\""))
    #expect(prepared.contains("height=\"360\""))
}
