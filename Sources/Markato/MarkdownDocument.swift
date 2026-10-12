import AppKit
import MarkdownCore

final class MarkdownDocument: NSDocument {
    private let sourceLock = NSLock()
    private var storedSource = TextRope()
    private var initialDecodedText: (revision:Int,text:String)?
    var source: TextRope { sourceLock.lock(); defer { sourceLock.unlock() }; return storedSource }
    private(set) var revision = 0
    private var encoding: String.Encoding = .utf8
    private var hasBOM = false
    private(set) var newline = "\n"
    let parser = ComrakWorker()
    var edited: ((NSRange, String, SourceEdit) -> Void)?
    override class var autosavesInPlace: Bool { true }
    override init() { super.init(); hasUndoManager = true; fileType = "Markdown" }
    override func makeWindowControllers() {
        // Parse on the worker while AppKit and Ultralight create the window. Comrak
        // prepares one AST; the first viewport receives only its records while
        // the complete manifest seeds the retained document trees.
        parser.request(rope:source,revision:revision,visible:NSRange(location:0,length:0),renderHTML:false) {result in
            if case .failure(let error)=result {NSLog("Initial syntax preparation failed: %@",error.localizedDescription)}
        }
        let controller = EditorWindowController(document: self)
        addWindowController(controller)
    }
    func replace(_ range: NSRange, with text: String, selection: NSRange? = nil, name: String = "Typing") {
        let previous = source.string(in: range)
        let inverse = NSRange(location:range.location,length:text.utf16.count)
        undoManager?.registerUndo(withTarget:self) { doc in
            doc.replace(inverse, with:previous, selection:range, name:name)
        }
        undoManager?.setActionName(name)
        sourceLock.lock(); storedSource = storedSource.replacing(range, with:text);initialDecodedText=nil;sourceLock.unlock()
        revision += 1
        let change:NSDocument.ChangeType=undoManager?.isUndoing == true ? .changeUndone : undoManager?.isRedoing == true ? .changeRedone : .changeDone
        // Native text callbacks arrive while NSTextStorage is inside its edit
        // transaction. Updating the title can synchronously draw the window;
        // defer that notification so TextKit never lays out an open edit.
        DispatchQueue.main.async { [weak self] in self?.updateChangeCount(change) }
        let edit = SourceEdit(range:range, insertedLength:text.utf16.count)
        parser.record(edit,revision:revision)
        edited?(selection ?? NSRange(location:range.location+text.utf16.count,length:0),text,edit)
    }
    func setInitialText(_ text: String) {
        let oldCount = source.count
        let nextRevision=revision+1
        let units=Array(text.utf16)
        // Comrak consumes the decoded immutable string while the edit-ready
        // rope is built on this thread. The first viewport request is queued
        // behind this parse and reuses the prepared native document.
        parser.prepareInitial(units,revision:nextRevision)
        #if DEBUG
        let ropeWork=TimingDiagnostics.shared.begin("document.rope")
        #endif
        let replacement=TextRope(units:units)
        #if DEBUG
        TimingDiagnostics.shared.end(ropeWork,values:["characters":Double(text.utf16.count)])
        #endif
        sourceLock.lock(); storedSource = replacement; sourceLock.unlock(); revision=nextRevision
        sourceLock.lock();initialDecodedText=(revision,text);sourceLock.unlock()
        edited?(NSRange(location:0,length:0),text,SourceEdit(range:NSRange(location:0,length:oldCount),insertedLength:text.utf16.count))
    }
    override func read(from data: Data, ofType typeName: String) throws {
        #if DEBUG
        let readWork=TimingDiagnostics.shared.begin("document.read")
        defer {TimingDiagnostics.shared.end(readWork,values:["bytes":Double(data.count)])}
        let decodeWork=TimingDiagnostics.shared.begin("document.decode")
        #endif
        let text: String?
        if data.starts(with:[0xff,0xfe]) || data.starts(with:[0xfe,0xff]) { encoding = .utf16; text = String(data:data,encoding:.utf16); hasBOM = true }
        else { encoding = .utf8; hasBOM = data.starts(with:[0xef,0xbb,0xbf]); text = String(data:hasBOM ? data.dropFirst(3) : data,encoding:.utf8) }
        #if DEBUG
        TimingDiagnostics.shared.end(decodeWork)
        #endif
        guard let text else { throw NSError(domain:NSCocoaErrorDomain,code:NSFileReadInapplicableStringEncodingError,userInfo:[NSLocalizedDescriptionKey:"The document must use UTF-8 or UTF-16 encoding."]) }
        setInitialText(text)
        newline = source.containsCRLF ? "\r\n" : "\n"
    }
    /// Reuses NSDocument's decoded String for the first TextKit population.
    /// The rope remains the authoritative editable representation after that.
    func takeInitialText(for revision:Int)->String? {
        sourceLock.lock();defer{sourceLock.unlock()}
        guard initialDecodedText?.revision==revision else{return nil}
        let text=initialDecodedText?.text;initialDecodedText=nil;return text
    }
    override func data(ofType typeName: String) throws -> Data {
        guard var data = source.string.data(using:encoding) else { throw NSError(domain:NSCocoaErrorDomain,code:NSFileWriteInapplicableStringEncodingError) }
        if encoding == .utf8 && hasBOM { data.insert(contentsOf:[0xef,0xbb,0xbf],at:0) }
        return data
    }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { true }
}
