import AppKit
import MarkdownCore

final class MarkdownDocument: NSDocument {
    private let sourceLock = NSLock()
    private var storedSource = TextRope()
    var source: TextRope { sourceLock.lock(); defer { sourceLock.unlock() }; return storedSource }
    private(set) var revision = 0
    private var encoding: String.Encoding = .utf8
    private var hasBOM = false
    private(set) var newline = "\n"
    private(set) var lastEditInvalidatesContext = false
    let parser = LezerWorker()
    var edited: ((NSRange, String, SourceEdit) -> Void)?
    override class var autosavesInPlace: Bool { true }
    override init() { super.init(); hasUndoManager = true; fileType = "Markdown" }
    override func makeWindowControllers() {
        // Parse syntax on its worker while AppKit and WebKit create the window.
        // The measured viewport request will reuse this revision's tree.
        parser.request(rope:source,revision:revision,visible:NSRange(location:0,length:0),renderHTML:false) {result in
            if case .failure(let error)=result {NSLog("Initial syntax preparation failed: %@",error.localizedDescription)}
        }
        let controller = EditorWindowController(document: self)
        addWindowController(controller)
    }
    func replace(_ range: NSRange, with text: String, selection: NSRange? = nil, name: String = "Typing") {
        let previous = source.string(in: range)
        let line = source.line(at:range.location)
        let lineText = source.string(in:source.lines(line,line+1))
        lastEditInvalidatesContext = ["`","~","$","\\[","\\]"].contains {previous.contains($0) || text.contains($0)}
            || lineText.range(of:#"^\s*\[[^\]]+\]:"#,options:.regularExpression) != nil
        let inverse = NSRange(location:range.location,length:text.utf16.count)
        undoManager?.registerUndo(withTarget:self) { doc in
            doc.replace(inverse, with:previous, selection:range, name:name)
        }
        undoManager?.setActionName(name)
        sourceLock.lock(); storedSource = storedSource.replacing(range, with:text); sourceLock.unlock()
        revision += 1
        updateChangeCount(undoManager?.isUndoing == true ? .changeUndone : undoManager?.isRedoing == true ? .changeRedone : .changeDone)
        let edit = SourceEdit(range:range, insertedLength:text.utf16.count)
        parser.record(edit,revision:revision)
        edited?(selection ?? NSRange(location:range.location+text.utf16.count,length:0),text,edit)
    }
    func setInitialText(_ text: String) {
        let oldCount = source.count
        sourceLock.lock(); storedSource = TextRope(text); sourceLock.unlock(); revision += 1
        parser.reset()
        lastEditInvalidatesContext = true
        edited?(NSRange(location:0,length:0),text,SourceEdit(range:NSRange(location:0,length:oldCount),insertedLength:text.utf16.count))
    }
    override func read(from data: Data, ofType typeName: String) throws {
        let text: String?
        if data.starts(with:[0xff,0xfe]) || data.starts(with:[0xfe,0xff]) { encoding = .utf16; text = String(data:data,encoding:.utf16); hasBOM = true }
        else { encoding = .utf8; hasBOM = data.starts(with:[0xef,0xbb,0xbf]); text = String(data:hasBOM ? data.dropFirst(3) : data,encoding:.utf8) }
        guard let text else { throw NSError(domain:NSCocoaErrorDomain,code:NSFileReadInapplicableStringEncodingError,userInfo:[NSLocalizedDescriptionKey:"The document must use UTF-8 or UTF-16 encoding."]) }
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        setInitialText(text)
    }
    override func data(ofType typeName: String) throws -> Data {
        guard var data = source.string.data(using:encoding) else { throw NSError(domain:NSCocoaErrorDomain,code:NSFileWriteInapplicableStringEncodingError) }
        if encoding == .utf8 && hasBOM { data.insert(contentsOf:[0xef,0xbb,0xbf],at:0) }
        return data
    }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { true }
}
