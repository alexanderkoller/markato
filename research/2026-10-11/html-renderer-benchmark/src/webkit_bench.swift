import Cocoa
import WebKit

func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

@MainActor final class Bench: NSObject, WKNavigationDelegate {
    let html: String
    let bytes: Int
    let startedAt: Double
    let constructMs: Double
    let webView: WKWebView
    let window: NSWindow
    var navigationAt = 0.0
    var height = 0
    var scrollResults: [Double] = []

    init(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        html = String(decoding: data, as: UTF8.self)
        bytes = data.count
        let a = now()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 760), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        constructMs = now() - a
        startedAt = now()
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        window.orderFrontRegardless()
        navigationAt = now()
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let didFinishMs = now() - navigationAt
        frame { [self] value in
            guard let result = value as? [String: Any], let h = result["height"] as? NSNumber else {
                failText("invalid first-frame result"); return
            }
            height = h.intValue
            let firstViewMs = now() - navigationAt
            let ys = [0, max(0, (height - 760) / 2), max(0, height - 760)]
            runScrolls(ys: ys, index: 0, didFinishMs: didFinishMs, firstViewMs: firstViewMs)
        }
    }

    func frame(_ done: @escaping (Any?) -> Void) {
        webView.takeSnapshot(with: nil) { _, snapshotError in
            if let snapshotError { self.fail(snapshotError); return }
            let script = "JSON.stringify({height:document.documentElement.scrollHeight,y:scrollY})"
            self.webView.evaluateJavaScript(script) { value, error in
                if let error { self.fail(error); return }
                guard let string = value as? String,
                      let data = string.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) else {
                    self.failText("invalid frame result"); return
                }
                done(object)
            }
        }
    }

    func runScrolls(ys: [Int], index: Int, didFinishMs: Double, firstViewMs: Double) {
        if index == ys.count {
            let a = now()
            webView.evaluateJavaScript("scrollTo(0,0);document.getElementById('edit-target').textContent='BENCH_START_X'") { _, error in
                if let error { self.fail(error); return }
                self.frame { _ in self.finish(didFinishMs: didFinishMs, firstViewMs: firstViewMs, editMs: now() - a) }
            }
            return
        }
        let a = now()
        webView.evaluateJavaScript("scrollTo(0,\(ys[index]))") { _, error in
            if let error { self.fail(error); return }
            self.frame { _ in
                self.scrollResults.append(now() - a)
                self.runScrolls(ys: ys, index: index + 1, didFinishMs: didFinishMs, firstViewMs: firstViewMs)
            }
        }
    }

    func finish(didFinishMs: Double, firstViewMs: Double, editMs: Double) {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let fields: [String: Any] = [
            "engine":"webkit", "html_bytes":bytes, "construct_ms":constructMs,
            "load_to_did_finish_ms":didFinishMs, "first_view_ms":firstViewMs,
            "document_height":height, "scroll_top_ms":scrollResults[0],
            "scroll_mid_ms":scrollResults[1], "scroll_end_ms":scrollResults[2],
            "visible_edit_ms":editMs, "max_rss_bytes":Int64(usage.ru_maxrss),
            "incremental_text_edit":true
        ]
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout); NSApp.terminate(nil)
    }

    func fail(_ error: Error) { failText(error.localizedDescription) }
    func failText(_ text: String) { fputs("webkit benchmark: \(text)\n", stderr); NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    do {
        let bench = try Bench(path: CommandLine.arguments[1])
        bench.start()
        withExtendedLifetime(bench) { app.run() }
    } catch {
        fputs("webkit benchmark: \(error)\n", stderr)
        exit(2)
    }
}
