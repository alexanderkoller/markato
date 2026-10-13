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
    #expect(html.contains("<section><h1>First</h1></section>"))
    #expect(html.contains("<section class=\"last-block\"><p>Second</p></section>"))
}

@Test func localImagesBecomePortableDataURLs() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:directory)}
    try Data([0x89,0x50,0x4e,0x47]).write(to:directory.appendingPathComponent("image.png"))
    let fragment="<img src=\"astra-asset://image/?source=image.png\">"
    let html=HTMLDocument.render(title:"Image",fragments:[fragment],baseURL:directory)
    #expect(html.contains("src=\"data:image/png;base64,iVBORw==\""))
    #expect(!html.contains("astra-asset:"))
}

@Test func remoteImagesRemainRemote() {
    let fragment="<img src=\"astra-asset://image/?source=https%3A%2F%2Fexample.com%2Fimage.png\">"
    let html=HTMLDocument.render(title:"Remote",fragments:[fragment])
    #expect(html.contains("src=\"https://example.com/image.png\""))
}
