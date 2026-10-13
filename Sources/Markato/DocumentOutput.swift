import AppKit
import HTMLPreview
import MarkdownCore
import PDFKit
import UniformTypeIdentifiers

private enum DocumentOutputError:LocalizedError {
    case renderFailed(String)
    case printFailed
    case printHelperUnavailable
    case printHelperFailed(String)

    var errorDescription:String? {
        switch self {
        case .renderFailed(let message): return "The document could not be rendered: \(message)"
        case .printFailed: return "The document could not be printed."
        case .printHelperUnavailable: return "Markato's print renderer is unavailable."
        case .printHelperFailed(let message): return "The printable document could not be created: \(message)"
        }
    }
}

private final class RenderedDocumentBuilder {
    private let worker=ComrakWorker()

    func build(rope:TextRope,revision:Int,title:String,baseURL:URL?,completion:@escaping (Result<String,Error>)->Void) {
        worker.request(rope:rope,revision:revision,visible:NSRange(location:0,length:rope.count)) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let parsed):
                guard parsed.revision==revision,let blocks=parsed.blocks else {
                    completion(.failure(DocumentOutputError.renderFailed("The renderer returned an incomplete document.")))
                    return
                }
                completion(.success(HTMLDocument.render(title:title,
                    fragments:blocks.map{$0.html?.string() ?? ""},baseURL:baseURL)))
            }
        }
    }
}

@MainActor final class DocumentOutputCoordinator:NSObject {
    private enum Job {
        case print(NSPrintInfo)
        case pdf(URL)
    }

    private unowned let document:MarkdownDocument
    private var builder:RenderedDocumentBuilder?
    private var printProcess:Process?
    private var temporaryDirectory:URL?
    private var pendingJob:Job?
    private(set) var isBusy=false

    init(document:MarkdownDocument) {self.document=document}
    deinit {
        printProcess?.terminate()
        if let temporaryDirectory {try? FileManager.default.removeItem(at:temporaryDirectory)}
    }

    func exportHTML(_ sender:Any?) {
        guard !isBusy else{return}
        let panel=NSSavePanel()
        panel.allowedContentTypes=[.html]
        panel.nameFieldStringValue=proposedName(extension:"html")
        present(panel) { [weak self] response in
            guard response == .OK,let url=panel.url else{return}
            self?.render { result in
                switch result {
                case .success(let html):
                    do {try html.write(to:url,atomically:true,encoding:.utf8);self?.finish()}
                    catch {self?.finish(error:error)}
                case .failure(let error): self?.finish(error:error)
                }
            }
        }
    }

    func exportPDF(_ sender:Any?) {
        guard !isBusy else{return}
        let panel=NSSavePanel()
        panel.allowedContentTypes=[.pdf]
        panel.nameFieldStringValue=proposedName(extension:"pdf")
        present(panel) { [weak self] response in
            guard response == .OK,let url=panel.url else{return}
            self?.beginPrint(.pdf(url))
        }
    }

    func printDocument(_ sender:Any?) {
        guard !isBusy else{return}
        let info=document.printInfo.copy() as! NSPrintInfo
        let panel=NSPrintPanel()
        panel.options.formUnion([.showsPaperSize,.showsOrientation,.showsScaling])
        if let window=document.windowControllers.first?.window {
            panel.beginSheet(using:info,on:window) { [weak self] result in
                guard result == .printed else{return}
                self?.beginPrint(.print(info))
            }
        } else if panel.runModal(with:info) == NSApplication.ModalResponse.OK.rawValue {
            beginPrint(.print(info))
        }
    }

    private func beginPrint(_ job:Job) {
        render { [weak self] result in
            guard let self else{return}
            switch result {
            case .failure(let error): self.finish(error:error)
            case .success(let html): self.generatePDF(from:html,for:job)
            }
        }
    }

    private func render(completion:@escaping (Result<String,Error>)->Void) {
        isBusy=true
        let rope=document.source,revision=document.revision
        let base=document.fileURL?.deletingLastPathComponent()
        let renderer=RenderedDocumentBuilder();builder=renderer
        renderer.build(rope:rope,revision:revision,title:document.displayName,baseURL:base,completion:completion)
    }

    private func generatePDF(from html:String,for job:Job) {
        do {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("Markato-\(UUID().uuidString)",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let input=directory.appendingPathComponent("document.html")
            let output=directory.appendingPathComponent("document.pdf")
            try html.write(to:input,atomically:true,encoding:.utf8)
            guard let helper=printHelperURL else {throw DocumentOutputError.printHelperUnavailable}
            let info: NSPrintInfo
            switch job {
            case .print(let selected): info=selected
            case .pdf: info=document.printInfo.copy() as! NSPrintInfo
            }
            let process=Process(),errors=Pipe()
            process.executableURL=helper
            process.arguments=[input.path,output.path,String(Double(info.paperSize.width)),String(Double(info.paperSize.height)),
                String(Double(info.leftMargin)),String(Double(info.rightMargin)),String(Double(info.topMargin)),String(Double(info.bottomMargin))]
            process.standardError=errors
            pendingJob=job;temporaryDirectory=directory;printProcess=process
            process.terminationHandler = { [weak self] completed in
                let message=String(data:errors.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
                DispatchQueue.main.async {self?.printHelperFinished(status:completed.terminationStatus,output:output,message:message)}
            }
            try process.run()
        } catch {finish(error:error)}
    }

    private var printHelperURL:URL? {
        let executable=Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates=[Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MarkatoPrintRenderer"),
                        executable?.appendingPathComponent("MarkatoPrintRenderer")].compactMap{$0}
        return candidates.first{FileManager.default.isExecutableFile(atPath:$0.path)}
    }

    private func printHelperFinished(status:Int32,output:URL,message:String) {
        guard status==0,let job=pendingJob else {
            let detail=message.trimmingCharacters(in:.whitespacesAndNewlines)
            finish(error:DocumentOutputError.printHelperFailed(detail.isEmpty ? "The renderer exited with status \(status).":detail))
            return
        }
        do {
            switch job {
            case .pdf(let destination):
                try exportAnnotatedPDF(from:output,to:destination)
                finish()
            case .print(let info):
                guard let pdf=PDFDocument(url:output),
                      let operation=pdf.printOperation(for:info,scalingMode:.pageScaleNone,autoRotate:false) else {
                    throw DocumentOutputError.printFailed
                }
                operation.showsPrintPanel=false;operation.showsProgressPanel=true
                finish(error:operation.run() ? nil:DocumentOutputError.printFailed)
            }
        } catch {finish(error:error)}
    }

    private func exportAnnotatedPDF(from sourceURL:URL,to destination:URL) throws {
        let source=document.source.string
        let comments=MarkdownComments.records(in:source)
        guard !comments.isEmpty else {
            try Data(contentsOf:sourceURL,options:.mappedIfSafe).write(to:destination,options:.atomic);return
        }
        guard let pdf=PDFDocument(url:sourceURL) else{throw DocumentOutputError.printFailed}
        let sourceText=source as NSString
        for comment in comments.sorted(by:{($0.anchorRange?.location ?? Int.max)<($1.anchorRange?.location ?? Int.max)}) {
            let value=comment.comment
            let header=value.created.isEmpty ? value.author:"\(value.author) · \(value.created)"
            let text="\(header)\n\n\(value.body)"
            let contents=value.status == .resolved ? "[Resolved]\n\n\(text)":text
            if !value.anchor.exact.isEmpty {
                var located:(matches:[PDFSelection],occurrence:Int)?
                for candidate in pdfSearchCandidates(value.anchor.exact) {
                    let matches=pdf.findString(candidate,withOptions:[.literal,.caseInsensitive])
                    let occurrence=sourceOccurrence(of:candidate,before:comment.anchorRange?.location ?? 0,in:sourceText)
                    if occurrence<matches.count {located=(matches,occurrence);break}
                }
                if let located {
                    let lines=located.matches[located.occurrence].selectionsByLine()
                    for (index,line) in lines.enumerated() {
                        guard let page=line.pages.first else{continue}
                        let bounds=line.bounds(for:page).insetBy(dx:-1,dy:-1)
                        let annotation=PDFAnnotation(bounds:bounds,forType:.highlight,withProperties:nil)
                        annotation.color=NSColor.systemYellow.withAlphaComponent(value.status == .open ? 0.45:0.2)
                        annotation.contents=contents;annotation.userName=value.author
                        annotation.modificationDate=ISO8601DateFormatter().date(from:value.created)
                        annotation.setValue(index==0 ? value.id:"\(value.id)-\(index)",forAnnotationKey:.name)
                        page.addAnnotation(annotation)
                    }
                    continue
                }
            }
            // Point and orphaned comments cannot be mapped to PDF text. Keep
            // their content as standard text-note annotations in the margin.
            if let page=pdf.page(at:0) {
                let box=page.bounds(for:.cropBox)
                let offset=CGFloat(page.annotations.filter{$0.type?.lowercased().contains("text") == true}.count)*22
                let bounds=NSRect(x:box.maxX-30,y:max(box.minY+8,box.maxY-30-offset),width:20,height:20)
                let annotation=PDFAnnotation(bounds:bounds,forType:.text,withProperties:nil)
                annotation.contents=contents;annotation.userName=value.author
                annotation.modificationDate=ISO8601DateFormatter().date(from:value.created)
                annotation.setValue(value.id,forAnnotationKey:.name);page.addAnnotation(annotation)
            }
        }
        guard pdf.write(to:destination) else{throw DocumentOutputError.printFailed}
    }

    private func sourceOccurrence(of needle:String,before offset:Int,in source:NSString)->Int {
        guard !needle.isEmpty,offset>0 else{return 0}
        var count=0,cursor=0
        let end=min(offset,source.length)
        while cursor<end {
            let found=source.range(of:needle,options:.literal,range:NSRange(location:cursor,length:end-cursor))
            guard found.location != NSNotFound,NSMaxRange(found)<=end else{break}
            count += 1;cursor=max(NSMaxRange(found),found.location+1)
        }
        return count
    }
    private func pdfSearchCandidates(_ source:String)->[String] {
        let plain=source.replacingOccurrences(of:"*",with:"").replacingOccurrences(of:"_",with:"")
            .replacingOccurrences(of:"`",with:"").replacingOccurrences(of:"~",with:"")
        var candidates=[source]
        if plain != source {candidates.append(plain)}
        let words=plain.split(whereSeparator:{$0.isWhitespace})
        if words.count>5 {candidates.append(words.prefix(6).joined(separator:" "))}
        if words.count>2 {candidates.append(words.prefix(3).joined(separator:" "))}
        return candidates.filter{!$0.isEmpty}.reduce(into:[String]()) {if !$0.contains($1) {$0.append($1)}}
    }

    private func proposedName(extension pathExtension:String)->String {
        let source=document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName ?? "Untitled"
        let name=source.isEmpty ? "Untitled":source
        return "\(name).\(pathExtension)"
    }

    private func present(_ panel:NSSavePanel,completion:@escaping (NSApplication.ModalResponse)->Void) {
        if let window=document.windowControllers.first?.window {panel.beginSheetModal(for:window,completionHandler:completion)}
        else {panel.begin(completionHandler:completion)}
    }

    private func finish(error:Error?=nil) {
        builder=nil;pendingJob=nil;printProcess=nil
        if let temporaryDirectory {try? FileManager.default.removeItem(at:temporaryDirectory)}
        temporaryDirectory=nil
        isBusy=false
        if let error {
            let alert=NSAlert(error:error)
            if let window=document.windowControllers.first?.window {alert.beginSheetModal(for:window)}
            else {alert.runModal()}
        }
    }
    #if DEBUG
    func debugExportPDF(to url:URL) {guard !isBusy else{return};beginPrint(.pdf(url))}
    #endif
}
