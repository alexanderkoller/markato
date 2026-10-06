import Foundation
import JavaScriptCore

/// A separate queue keeps immediate viewport rendering independent of a full syntax parse.
public final class HTMLWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label:"org.astramarkdown.local-html",qos:.userInitiated)
    private var context:JSContext?
    private let lock = NSLock()
    private var generation = 0
    public init() {}
    public func request(text:String,from:Int,revision:Int,completion:@escaping(Result<ParseResult,Error>)->Void) {
        let waiting=TimingDiagnostics.shared.begin("html.local.queue.wait")
        lock.lock(); generation += 1; let token=generation; lock.unlock()
        queue.async { [self] in
            TimingDiagnostics.shared.end(waiting)
            lock.lock(); let current=token==generation; lock.unlock(); guard current else { return }
            let work=TimingDiagnostics.shared.begin("html.local.work")
            defer {TimingDiagnostics.shared.end(work,values:["revision":Double(revision),"sourceCharacters":Double(text.utf16.count)])}
            do {
                if context == nil {
                    let c=JSContext()!
                    guard let url=Bundle.module.url(forResource:"html",withExtension:"js") else { throw LezerWorker.WorkerError.message("Missing HTML renderer") }
                    c.evaluateScript(try String(contentsOf:url,encoding:.utf8));context=c
                }
                let c=context!;c.exception=nil
                let javascript=TimingDiagnostics.shared.begin("html.local.javascript")
                let value=c.objectForKeyedSubscript("astraLocal")!.call(withArguments:[text,from,revision])
                TimingDiagnostics.shared.end(javascript)
                if let error=c.exception { throw LezerWorker.WorkerError.message(error.toString()) }
                guard let json=value?.toString(),let data=json.data(using:.utf8) else { throw LezerWorker.WorkerError.message("Invalid HTML result") }
                let result=try JSONDecoder().decode(ParseResult.self,from:data)
                lock.lock();let latest=token==generation;lock.unlock()
                if latest {
                    let delivery=TimingDiagnostics.shared.begin("html.local.callback.wait")
                    DispatchQueue.main.async {TimingDiagnostics.shared.end(delivery);completion(.success(result))}
                }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
}
