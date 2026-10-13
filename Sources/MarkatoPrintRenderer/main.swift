import AppKit
import PDFKit
import WebKit

private func fail(_ message:String,_ status:Int32=1)->Never {
    FileHandle.standardError.write(Data((message+"\n").utf8))
    exit(status)
}

@MainActor private final class Renderer:NSObject,WKNavigationDelegate {
    private let input:URL,output:URL,printInfo:NSPrintInfo
    private var webView:WKWebView?
    private var hostWindow:NSWindow?
    private let assembledPDF=PDFDocument()

    init(arguments:[String]) {
        guard arguments.count==8,
              let width=Double(arguments[2]),let height=Double(arguments[3]),
              let left=Double(arguments[4]),let right=Double(arguments[5]),
              let top=Double(arguments[6]),let bottom=Double(arguments[7]) else {
            fail("Usage: MarkatoPrintRenderer input.html output.pdf width height left right top bottom",2)
        }
        input=URL(fileURLWithPath:arguments[0]);output=URL(fileURLWithPath:arguments[1])
        let info=NSPrintInfo()
        info.paperSize=NSSize(width:width,height:height)
        info.leftMargin=left;info.rightMargin=right;info.topMargin=top;info.bottomMargin=bottom
        info.horizontalPagination = .fit;info.verticalPagination = .automatic
        info.isHorizontallyCentered=false;info.isVerticallyCentered=false
        printInfo=info
    }

    func start() {
        let configuration=WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let printableWidth=max(1,printInfo.paperSize.width-printInfo.leftMargin-printInfo.rightMargin)
        let printableHeight=max(1,printInfo.paperSize.height-printInfo.topMargin-printInfo.bottomMargin)
        let web=WKWebView(frame:NSRect(x:0,y:0,width:printableWidth,height:printableHeight),
                          configuration:configuration)
        let window=NSWindow(contentRect:web.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.contentView=web;hostWindow=window
        web.navigationDelegate=self;webView=web
        web.loadFileURL(input,allowingReadAccessTo:input.deletingLastPathComponent())
    }

    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        let waitForResources=#"""
        const images = Array.from(document.images).map(image => {
          if (image.complete) return Promise.resolve();
          return new Promise(resolve => {
            image.addEventListener('load', resolve, {once:true});
            image.addEventListener('error', resolve, {once:true});
          });
        });
        await Promise.race([
          Promise.all(images),
          new Promise(resolve => setTimeout(resolve, 5000))
        ]);
        if (document.fonts) await document.fonts.ready;
        const style = document.createElement('style');
        style.textContent = `
          :root { color-scheme: light; --fg-default:#1f2328; --fg-muted:#59636e;
            --fg-accent:#0969da; --bg-default:#fff; --bg-muted:#f6f8fa;
            --bg-neutral-muted:#818b981f; --border-default:#d1d9e0;
            --border-muted:#d1d9e0b3; --danger:#d1242f; }
          html, body { background:white; } #preview { padding:0; }
          a { color:inherit; text-decoration:underline; }
        `;
        document.head.appendChild(style);
        const pageHeight = pageHeightValue;
        for (const section of document.querySelectorAll('#preview > section')) {
          const rect = section.getBoundingClientRect();
          const top = rect.top + window.scrollY;
          const offset = ((top % pageHeight) + pageHeight) % pageHeight;
          if (rect.height <= pageHeight && offset + rect.height > pageHeight) {
            const current = parseFloat(getComputedStyle(section).marginTop) || 0;
            section.style.marginTop = `${current + pageHeight - offset}px`;
          }
        }
        return Math.max(document.documentElement.scrollHeight, document.body.scrollHeight);
        """#
        let pageHeight=max(1,printInfo.paperSize.height-printInfo.topMargin-printInfo.bottomMargin)
        webView.callAsyncJavaScript(waitForResources,arguments:["pageHeightValue":pageHeight],in:nil,in:.page) { [weak self] result in
            guard let self else{return}
            switch result {
            case .failure(let error): fail(error.localizedDescription)
            case .success(let value):
                guard let height=value as? Double else {fail("WebKit returned an invalid document height.")}
                let pages=max(1,Int(ceil(height/pageHeight)))
                self.capturePage(0,count:pages,pageHeight:pageHeight)
            }
        }
    }

    private func capturePage(_ index:Int,count:Int,pageHeight:CGFloat) {
        guard let webView else {fail("The WebKit renderer was released early.")}
        if index==count {
            guard assembledPDF.write(to:output) else {fail("The PDF could not be written.")}
            exit(EXIT_SUCCESS)
        }
        let width=max(1,printInfo.paperSize.width-printInfo.leftMargin-printInfo.rightMargin)
        let configuration=WKPDFConfiguration()
        configuration.rect=CGRect(x:0,y:CGFloat(index)*pageHeight,width:width,height:pageHeight)
        webView.createPDF(configuration:configuration) { [weak self] result in
            guard let self else{return}
            switch result {
            case .failure(let error): fail(error.localizedDescription)
            case .success(let data):
                guard let page=PDFDocument(data:data)?.page(at:0) else {fail("WebKit returned an invalid PDF page.")}
                let media=CGRect(x:-self.printInfo.leftMargin,y:-self.printInfo.bottomMargin,
                    width:self.printInfo.paperSize.width,height:self.printInfo.paperSize.height)
                page.setBounds(media,for:.mediaBox);page.setBounds(media,for:.cropBox)
                self.assembledPDF.insert(page,at:self.assembledPDF.pageCount)
                self.capturePage(index+1,count:count,pageHeight:pageHeight)
            }
        }
    }

    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {fail(error.localizedDescription)}
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {fail(error.localizedDescription)}
}

MainActor.assumeIsolated {
    let arguments=Array(CommandLine.arguments.dropFirst())
    let application=NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let renderer=Renderer(arguments:arguments)
    renderer.start()
    application.run()
}
