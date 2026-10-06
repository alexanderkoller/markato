import AppKit
import ImageIO
import WebKit
import MarkdownCore

struct LoadedImage: @unchecked Sendable {
    let image: CGImage
    let sourceURL: URL
    var cost: Int { image.bytesPerRow*image.height }
}
actor ImageCache {
    static let shared = ImageCache()
    private var entries = [URL:(LoadedImage,Date)]()
    private var cost = 0
    private let limit = 128*1024*1024
    func load(_ url:URL) async throws -> LoadedImage {
        if let (image,_) = entries[url] { entries[url] = (image,Date()); return image }
        let data: Data
        if url.isFileURL { data = try Data(contentsOf:url,options:.mappedIfSafe) }
        else {
            guard ["https","http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
            var request = URLRequest(url:url); request.timeoutInterval = 30
            let (bytes,response) = try await URLSession.shared.data(for:request)
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) { throw URLError(.badServerResponse) }
            data = bytes
        }
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:2048,
                kCGImageSourceShouldCacheImmediately:true
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        let loaded = LoadedImage(image:image,sourceURL:url)
        while cost+loaded.cost > limit, let oldest = entries.min(by:{$0.value.1<$1.value.1}) {
            cost -= oldest.value.0.cost; entries.removeValue(forKey:oldest.key)
        }
        entries[url] = (loaded,Date()); cost += loaded.cost; return loaded
    }
    func png(_ url:URL) async throws -> Data {
        let work=TimingDiagnostics.shared.begin("image.prepare")
        defer {TimingDiagnostics.shared.end(work)}
        let loaded=try await load(url)
        guard let data=NSBitmapImageRep(cgImage:loaded.image).representation(using:.png,properties:[:]) else {throw URLError(.cannotDecodeContentData)}
        return data
    }
    func clear() { entries.removeAll(); cost = 0 }
}

/// URL scheme tasks are cancelled before any further WebKit callback is sent.
@MainActor final class PreviewAssets:NSObject,WKURLSchemeHandler {
    var baseURL:URL?
    private var jobs=[ObjectIdentifier:Task<Void,Never>]()
    func webView(_ webView:WKWebView,start urlSchemeTask:WKURLSchemeTask) {
        let id=ObjectIdentifier(urlSchemeTask)
        guard let requestURL=urlSchemeTask.request.url,
              let source=URLComponents(url:requestURL,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="source"})?.value,
              let url=URL(string:source,relativeTo:baseURL)?.absoluteURL,
              ["file","http","https"].contains(url.scheme?.lowercased() ?? "") else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL));return
        }
        jobs[id]=Task { [weak self] in
            do {
                let data=try await ImageCache.shared.png(url)
                guard !Task.isCancelled,self?.jobs[id] != nil else{return}
                urlSchemeTask.didReceive(URLResponse(url:requestURL,mimeType:"image/png",expectedContentLength:data.count,textEncodingName:nil))
                urlSchemeTask.didReceive(data);urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled,self?.jobs[id] != nil else{return}
                NSLog("Preview image failed: %@",error.localizedDescription)
                urlSchemeTask.didFailWithError(error)
            }
            self?.jobs.removeValue(forKey:id)
        }
    }
    func webView(_ webView:WKWebView,stop urlSchemeTask:WKURLSchemeTask) {
        jobs.removeValue(forKey:ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
