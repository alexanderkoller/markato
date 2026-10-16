import Foundation

public enum HTMLDocument {
    public static func render(title:String,fragments:[String],baseURL:URL?=nil)->String {
        let assets=HTMLAssetPreparer()
        let sections=fragments.enumerated().map { index,fragment in
            let body=assets.prepare(fragment,baseURL:baseURL)
            let first=index==0 ? " document-first":""
            return "<section class=\"astra-preview-block\(first)\">\(body)</section>"
        }.joined(separator:"\n")
        let safeTitle=escape(title)
        return #"""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data: http: https:; style-src 'unsafe-inline'; font-src data:">
        <title>\#(safeTitle)</title>
        <style>\#(HTMLPreviewResources.stylesheet)\n\#(printStylesheet)</style>
        </head>
        <body><main id="preview">\#(sections)</main></body>
        </html>
        """#
    }

    private static func escape(_ text:String)->String {
        text.replacingOccurrences(of:"&",with:"&amp;")
            .replacingOccurrences(of:"<",with:"&lt;")
            .replacingOccurrences(of:">",with:"&gt;")
            .replacingOccurrences(of:"\"",with:"&quot;")
    }

    private static let printStylesheet=#"""
    @media print {
      :root {
        color-scheme: light;
        --fg-default: #1f2328;
        --fg-muted: #59636e;
        --fg-accent: #0969da;
        --bg-default: #ffffff;
        --bg-muted: #f6f8fa;
        --bg-neutral-muted: #818b981f;
        --border-default: #d1d9e0;
        --border-muted: #d1d9e0b3;
        --danger: #d1242f;
      }
      @page { size: A4 portrait; margin: 15mm; }
      html, body { background: white; font-size: 11pt; }
      #preview { padding: 0; }
      pre, blockquote, table, tr, img, .katex-display, .mermaid-diagram {
        break-inside: avoid;
      }
      img { max-width: 100%; max-height: 267mm; object-fit: contain; }
      table { max-width: 100%; overflow-wrap: anywhere; }
      thead { display: table-header-group; }
      a { color: inherit; text-decoration: underline; }
    }
    """#
}
