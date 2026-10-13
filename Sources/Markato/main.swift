import AppKit
import MarkdownCore
import UniformTypeIdentifiers

private let markdownFilenameExtensions:Set<String> = ["md","markdown","mdown","mkd"]

private enum DocumentRequestError: LocalizedError {
    case tooManyFiles(Int)
    case missingFile(String)
    case notRegularFile(String)
    case notMarkdown(String)

    var errorDescription:String? {
        switch self {
        case .tooManyFiles(let count): return "Markato opens one Markdown file per request, but received \(count)."
        case .missingFile(let path): return "The file does not exist: \(path)"
        case .notRegularFile(let path): return "The path is not a regular file: \(path)"
        case .notMarkdown(let path): return "The file is not a supported Markdown file: \(path)"
        }
    }
}

private func validatedMarkdownURL(_ path:String) throws -> URL {
    let url=URL(fileURLWithPath:path).standardizedFileURL
    guard FileManager.default.fileExists(atPath:url.path) else {throw DocumentRequestError.missingFile(path)}
    let values=try url.resourceValues(forKeys:[.isRegularFileKey])
    guard values.isRegularFile == true else {throw DocumentRequestError.notRegularFile(path)}
    guard markdownFilenameExtensions.contains(url.pathExtension.lowercased()) else {throw DocumentRequestError.notMarkdown(path)}
    return url
}

private struct LaunchConfiguration {
    let opensSample:Bool
    let documentURL:URL?

    static func parse(_ arguments:[String]) throws ->LaunchConfiguration {
        let values=Array(arguments.dropFirst())
        if values.contains("--sample") {return LaunchConfiguration(opensSample:true,documentURL:nil)}
        var paths=[String](),optionsEnded=false
        for value in values {
            if !optionsEnded && value == "--" {optionsEnded=true;continue}
            if !optionsEnded && value.hasPrefix("-") {continue}
            paths.append(value)
        }
        guard paths.count<=1 else {throw DocumentRequestError.tooManyFiles(paths.count)}
        return LaunchConfiguration(opensSample:false,documentURL:try paths.first.map(validatedMarkdownURL))
    }
}

#if DEBUG
@_cdecl("astra_timing_start")
func startProfileRecording() { TimingDiagnostics.shared.start() }
@_cdecl("astra_timing_export")
func exportProfileRecording(_ path:UnsafePointer<CChar>) {
    try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:String(cString:path)))
}
#endif

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let launchConfiguration:LaunchConfiguration
    private var receivedDocumentOpenRequest=false
    private var openedStartupFallback=false
    fileprivate init(launchConfiguration:LaunchConfiguration) {self.launchConfiguration=launchConfiguration}
    private var currentEditor:EditorWindowController? {
        for window in [NSApp.keyWindow,NSApp.mainWindow].compactMap({$0}) {
            if let controller = window.windowController as? EditorWindowController { return controller }
            for document in NSDocumentController.shared.documents {
                if let controller = document.windowControllers.first(where:{$0.window === window}) as? EditorWindowController { return controller }
            }
        }
        return NSDocumentController.shared.documents.last?.windowControllers.first as? EditorWindowController
    }
    @objc func undo(_ sender:Any?) { currentEditor?.undo(sender) }
    @objc func redo(_ sender:Any?) { currentEditor?.redo(sender) }
    @objc func showFind(_ sender:Any?) { currentEditor?.showFind(sender) }
    @objc func findNext(_ sender:Any?) { currentEditor?.findNext(sender) }
    @objc func findPrevious(_ sender:Any?) { currentEditor?.findPrevious(sender) }
    @objc func toggleSidebar(_ sender:Any?) { currentEditor?.toggleSidebar(sender) }
    @objc func togglePreview(_ sender:Any?) { currentEditor?.togglePreview(sender) }
    @objc func increaseFont(_ sender:Any?) { currentEditor?.increaseFont(sender) }
    @objc func decreaseFont(_ sender:Any?) { currentEditor?.decreaseFont(sender) }
    @objc func performMarkdownCommand(_ sender:Any?) { currentEditor?.performMarkdownCommand(sender) }
    @objc func saveDocument(_ sender:Any?) { (currentEditor?.document as? NSDocument)?.save(sender) }
    @objc func saveDocumentAs(_ sender:Any?) { (currentEditor?.document as? NSDocument)?.saveAs(sender) }
    @objc func revertDocumentToSaved(_ sender:Any?) { (currentEditor?.document as? NSDocument)?.revertToSaved(sender) }
    @objc func newDocument(_ sender:Any?) {openUntitledDocument()}
    #if DEBUG
    @objc func toggleTimingDiagnostics(_ sender:Any?) {
        if TimingDiagnostics.shared.isRecording {TimingDiagnostics.shared.stop()}
        else {TimingDiagnostics.shared.start()}
    }
    @objc func saveTimingReport(_ sender:Any?) {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json]
        panel.nameFieldStringValue="Markato Timings.json"
        let complete:@MainActor (NSApplication.ModalResponse)->Void = { [weak self] response in
            guard response == .OK,let url=panel.url else{return}
            let snapshot=TimingDiagnostics.shared.snapshot()
            let editor=self?.currentEditor
            let info=ProcessInfo.processInfo
            var metadata=["applicationVersion":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown",
                          "os":info.operatingSystemVersionString,"processors":String(info.processorCount),"physicalMemoryBytes":String(info.physicalMemory),
                          "maximumScreenRefreshHz":String(NSScreen.main?.maximumFramesPerSecond ?? 0)]
            if let editor,let document=editor.document as? MarkdownDocument {
                metadata["documentCharacters"]=String(document.source.count)
                metadata["documentRevision"]=String(document.revision)
                metadata["sourceDocumentCharacters"]=String(editor.source.documentRange.length)
                metadata["previewWidth"]=String(Double(editor.preview.bounds.width))
                metadata["previewHeight"]=String(Double(editor.preview.bounds.height))
                metadata["mountedFragments"]=String(editor.preview.preparedFragmentCount)
                metadata["cachedBlocks"]=String(editor.cachedBlockCount)
                metadata["cacheBytes"]=String(editor.cachedByteCost)
            }
            let reportMetadata=metadata
            DispatchQueue.global(qos:.utility).async {
                do {try snapshot.json(metadata:reportMetadata).write(to:url,options:.atomic)}
                catch {DispatchQueue.main.async {let alert=NSAlert(error:error);alert.runModal()}}
            }
        }
        if let window=currentEditor?.window {panel.beginSheetModal(for:window,completionHandler:complete)}
        else {panel.begin(completionHandler:complete)}
    }
    #endif
    func validateMenuItem(_ menuItem:NSMenuItem)->Bool {
        if menuItem.action == #selector(newDocument(_:)) {return true}
        #if DEBUG
        if menuItem.action == #selector(toggleTimingDiagnostics(_:)) {
            menuItem.title=TimingDiagnostics.shared.isRecording ? "Stop Timing Diagnostics":"Start Timing Diagnostics"
            return true
        }
        if menuItem.action == #selector(saveTimingReport(_:)) {return TimingDiagnostics.shared.hasEvents}
        #endif
        return currentEditor?.validateMenuItem(menuItem) ?? false
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--diagnostics") {TimingDiagnostics.shared.start()}
        let checking=CommandLine.arguments.contains("--integration-test") || CommandLine.arguments.contains("--smoke-test")
        let checkingEmptyEdits=CommandLine.arguments.contains("--integration-empty-edits")
        let checkingDefaultStartup=ProcessInfo.processInfo.environment["MARKATO_INTEGRATION_DEFAULT_STARTUP"] == "1"
        let checkingFinderPath=CommandLine.arguments.first(where:{$0.hasPrefix("--integration-finder-document=")})
            .map{String($0.dropFirst("--integration-finder-document=".count))}
        let checkingStartup=CommandLine.arguments.contains("--integration-startup") || checkingDefaultStartup || checkingFinderPath != nil
        #else
        let checking=false
        let checkingDefaultStartup=false
        let checkingFinderPath:String?=nil
        let checkingStartup=false
        #endif
        buildMenus()
        if launchConfiguration.opensSample || (checking && !checkingStartup) {
            let document=MarkdownDocument()
            #if DEBUG
            document.setInitialText(checkingEmptyEdits ? "" : Self.sample)
            #else
            document.setInitialText(Self.sample)
            #endif
            NSDocumentController.shared.addDocument(document); document.makeWindowControllers()
            #if DEBUG
            if checking {document.windowControllers.first?.window?.setFrameOrigin(NSPoint(x:-10000,y:0))}
            document.showWindows()
            if CommandLine.arguments.contains("--integration-test") { DispatchQueue.main.asyncAfter(deadline:.now()+1) { IntegrationCheck.run(document) } }
            if CommandLine.arguments.contains("--smoke-test") {
                let collapsed=CommandLine.arguments.contains("--smoke-sidebar-collapsed")
                let expanded=CommandLine.arguments.contains("--smoke-sidebar-expanded")
                let wholeWindow=CommandLine.arguments.contains("--smoke-whole-window")
                if collapsed,(document.windowControllers.first as? EditorWindowController)?.isSidebarVisible == true {
                    (document.windowControllers.first as? EditorWindowController)?.toggleSidebar(nil)
                }
                if expanded,(document.windowControllers.first as? EditorWindowController)?.isSidebarVisible == false {
                    (document.windowControllers.first as? EditorWindowController)?.toggleSidebar(nil)
                }
                if wholeWindow {
                    NSApp.activate(ignoringOtherApps:true)
                    document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+3) {
                    guard let window = document.windowControllers.first?.window,let contentView = window.contentView else { exit(2) }
                    let view=wholeWindow ? contentView.superview ?? contentView:contentView
                    guard
                          let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { exit(2) }
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    let path=wholeWindow ? "/private/tmp/markato-smoke-whole-window.png":
                        collapsed ? "/private/tmp/markato-smoke-collapsed.png":"/private/tmp/markato-smoke.png"
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path))
                    print("SMOKE: windows=\(NSApp.windows.count), nativeGlyphLayout=\((document.windowControllers.first as? EditorWindowController)?.source.textView.layoutManager != nil), previewRevision=\((document.windowControllers.first as? EditorWindowController)?.preview.lastRevision ?? -1)")
                    print((document.windowControllers.first as? EditorWindowController)?.preview.debugGeometry() ?? "No preview")
                    exit(EXIT_SUCCESS)
                }
            }
            #else
            document.showWindows()
            #endif
        } else if launchConfiguration.documentURL == nil {
            scheduleStartupDocumentFallback()
            #if DEBUG
            if let path=checkingFinderPath {
                DispatchQueue.main.async { [self] in
                    receivedDocumentOpenRequest=true
                    openMarkdownFiles([path]) {_ in}
                }
            }
            #endif
        }
        #if DEBUG
        if checkingStartup {
            DispatchQueue.main.asyncAfter(deadline:.now()+3) { [self,launchConfiguration] in
                let documents=NSDocumentController.shared.documents
                let finderURL=checkingFinderPath.flatMap{try? validatedMarkdownURL($0)}
                let expectedURL=launchConfiguration.documentURL ?? finderURL
                guard documents.count==1,let document=documents.first as? MarkdownDocument,
                      document.windowControllers.count==1,
                      let window=document.windowControllers.first?.window,
                      window.tabbingMode == .disallowed,window.isVisible,
                      NSScreen.screens.contains(where:{$0.visibleFrame.intersects(window.frame)}),
                      document.fileURL?.standardizedFileURL == expectedURL?.standardizedFileURL,
                      expectedURL != nil || document.source.count==0,
                      !checkingDefaultStartup || openedStartupFallback else {
                    let failedWindow=documents.first?.windowControllers.first?.window
                    let failedDocument=documents.first as? MarkdownDocument
                    let onScreen=failedWindow.map{window in NSScreen.screens.contains(where:{$0.visibleFrame.intersects(window.frame)})} ?? false
                    print("STARTUP FAILED: documents=\(documents.count), controllers=\(documents.first?.windowControllers.count ?? -1), visible=\(failedWindow?.isVisible ?? false), onScreen=\(onScreen), tabbing=\(String(describing:failedWindow?.tabbingMode)), file=\(failedDocument?.fileURL?.path ?? "nil"), expected=\(expectedURL?.path ?? "nil"), characters=\(failedDocument?.source.count ?? -1), fallback=\(openedStartupFallback), frame=\(String(describing:failedWindow?.frame))")
                    exit(2)
                }
                print("STARTUP: empty=\(document.source.count==0), file=\(document.fileURL?.path ?? "untitled"), visible=true, tabbing=disallowed, fallback=\(openedStartupFallback)")
                if CommandLine.arguments.contains("--integration-new-document") {
                    NSApp.mainMenu?.update()
                    guard let item=NSApp.mainMenu?.item(withTitle:"File")?.submenu?.item(withTitle:"New"),
                          item.isEnabled,item.action == #selector(newDocument(_:)),
                          NSApp.sendAction(item.action!,to:item.target,from:item) else {
                        print("NEW DOCUMENT FAILED: menu action is not routed to Markato")
                        exit(2)
                    }
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                        let documents=NSDocumentController.shared.documents
                        let windows=documents.flatMap(\.windowControllers).compactMap(\.window)
                        guard documents.count==2,windows.count==2,
                              windows.allSatisfy({$0.isVisible && $0.tabbingMode == .disallowed}) else {
                            print("NEW DOCUMENT FAILED: documents=\(documents.count), windows=\(windows.count)")
                            exit(2)
                        }
                        print("NEW DOCUMENT: documents=2, visibleWindows=2, tabbing=disallowed")
                        exit(EXIT_SUCCESS)
                    }
                    return
                }
                if let option=CommandLine.arguments.first(where:{$0.hasPrefix("--integration-second-document=")}) {
                    let path=String(option.dropFirst("--integration-second-document=".count))
                    openMarkdownFiles([path]) {success in
                        let documents=NSDocumentController.shared.documents
                        let windows=documents.flatMap(\.windowControllers).compactMap(\.window)
                        guard success,documents.count==2,windows.count==2,
                              windows.allSatisfy({$0.isVisible && $0.tabbingMode == .disallowed}) else {
                            print("SECOND OPEN FAILED: documents=\(documents.count), windows=\(windows.count)")
                            exit(2)
                        }
                        print("SECOND OPEN: documents=2, visibleWindows=2, tabbing=disallowed")
                        exit(EXIT_SUCCESS)
                    }
                    return
                }
                exit(EXIT_SUCCESS)
            }
        }
        if !checking && !checkingStartup {NSApp.activate(ignoringOtherApps:true)}
        #else
        if !checking {NSApp.activate(ignoringOtherApps:true)}
        #endif
    }
    func applicationWillFinishLaunching(_ notification:Notification) {NSWindow.allowsAutomaticWindowTabbing=false}
    func applicationShouldOpenUntitledFile(_ sender:NSApplication) -> Bool {false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        if !flag && NSDocumentController.shared.documents.isEmpty {openUntitledDocument()}
        return true
    }
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        receivedDocumentOpenRequest=true
        openMarkdownFiles(filenames) {success in sender.reply(toOpenOrPrint:success ? .success:.failure)}
    }
    private func scheduleStartupDocumentFallback() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { [weak self] in
            guard let self,!receivedDocumentOpenRequest,NSDocumentController.shared.documents.isEmpty else{return}
            openedStartupFallback=true
            openUntitledDocument()
        }
    }
    private func openUntitledDocument() {
        let document=MarkdownDocument()
        NSDocumentController.shared.addDocument(document);document.makeWindowControllers();document.showWindows()
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    private func openMarkdownFiles(_ filenames:[String],completion:@escaping (Bool)->Void) {
        guard filenames.count==1 else {
            present(DocumentRequestError.tooManyFiles(filenames.count));completion(false);return
        }
        do {
            let url=try validatedMarkdownURL(filenames[0])
            NSDocumentController.shared.openDocument(withContentsOf:url,display:true) { document,_,error in
                if let error {self.present(error);completion(false)}
                else {
                    document?.showWindows()
                    document?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps:true)
                    completion(true)
                }
            }
        } catch {
            present(error);completion(false)
        }
    }
    private func present(_ error:Error) {NSAlert(error:error).runModal()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    private func buildMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        func submenu(_ title:String)->NSMenu { let item=NSMenuItem(); item.title=title;let menu=NSMenu(title:title);item.submenu=menu;main.addItem(item);return menu }
        func add(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String="",_ modifiers:NSEvent.ModifierFlags = .command,
                 tag:Int?=nil) {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.keyEquivalentModifierMask=modifiers
            if let tag {item.tag=tag}
            let routed:Set<String> = ["undo:","redo:","showFind:","findNext:","findPrevious:","toggleSidebar:","togglePreview:","increaseFont:","decreaseFont:","performMarkdownCommand:","saveDocument:","saveDocumentAs:","revertDocumentToSaved:","newDocument:"]
            if routed.contains(NSStringFromSelector(action)) { item.target = self }
            if action == #selector(NSDocumentController.openDocument(_:)) { item.target = NSDocumentController.shared }
            menu.addItem(item)
        }
        let app=submenu("Markato")
        add(app,"About Markato",#selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator());let services=NSMenuItem(title:"Services",action:nil,keyEquivalent:"");services.submenu=NSMenu();app.addItem(services);NSApp.servicesMenu=services.submenu
        app.addItem(.separator());add(app,"Hide Markato",#selector(NSApplication.hide(_:)),"h");add(app,"Hide Others",#selector(NSApplication.hideOtherApplications(_:)),"h",[.command,.option]);add(app,"Show All",#selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator());add(app,"Quit Markato",#selector(NSApplication.terminate(_:)),"q")
        let file=submenu("File")
        add(file,"New",#selector(newDocument(_:)),"n");add(file,"Open…",#selector(NSDocumentController.openDocument(_:)),"o")
        file.addItem(.separator());add(file,"Close",#selector(NSWindow.performClose(_:)),"w");add(file,"Save",#selector(NSDocument.save(_:)),"s");add(file,"Save As…",#selector(NSDocument.saveAs(_:)),"s",[.command,.shift])
        add(file,"Revert to Saved…",#selector(NSDocument.revertToSaved(_:)))
        let edit=submenu("Edit")
        add(edit,"Undo",#selector(EditorWindowController.undo(_:)),"z");add(edit,"Redo",#selector(EditorWindowController.redo(_:)),"z",[.command,.shift]);edit.addItem(.separator())
        add(edit,"Cut",#selector(NSText.cut(_:)),"x");add(edit,"Copy",#selector(NSText.copy(_:)),"c");add(edit,"Paste",#selector(NSText.paste(_:)),"v");add(edit,"Select All",#selector(NSText.selectAll(_:)),"a")
        edit.addItem(.separator());add(edit,"Find…",#selector(EditorWindowController.showFind(_:)),"f");add(edit,"Find Next",#selector(EditorWindowController.findNext(_:)),"g");add(edit,"Find Previous",#selector(EditorWindowController.findPrevious(_:)),"g",[.command,.shift])
        let format=submenu("Format")
        func formatItem(_ title:String,_ command:MarkdownMenuCommand,_ key:String="",_ modifiers:NSEvent.ModifierFlags = .command) {
            add(format,title,#selector(performMarkdownCommand(_:)),key,modifiers,tag:command.rawValue)
        }
        formatItem("Bold",.bold,"b");formatItem("Italic",.italic,"i")
        formatItem("Strikethrough",.strikethrough,"x",[.command,.shift])
        formatItem("Inline Code",.inlineCode,"k");formatItem("Link",.link,"k",[.command,.shift])
        format.addItem(.separator())
        let headings=NSMenu(title:"Heading")
        let headingItem=NSMenuItem(title:"Heading",action:nil,keyEquivalent:"");headingItem.submenu=headings;format.addItem(headingItem)
        for (title,command,key) in [("Heading 1",MarkdownMenuCommand.heading1,"1"),("Heading 2",.heading2,"2"),
            ("Heading 3",.heading3,"3"),("Heading 4",.heading4,"4"),("Heading 5",.heading5,"5"),
            ("Heading 6",.heading6,"6"),("Paragraph",.paragraph,"0")] {
            add(headings,title,#selector(performMarkdownCommand(_:)),key,.command,tag:command.rawValue)
        }
        formatItem("Bulleted List",.bulletedList,"u",[.command,.shift])
        formatItem("Numbered List",.numberedList,"o",[.command,.shift])
        formatItem("Blockquote",.blockquote,"b",[.command,.shift])
        format.addItem(.separator())
        formatItem("Insert Image…",.insertImage,"i",[.command,.shift])
        formatItem("Insert Table",.insertTable,"t",[.command,.option])
        formatItem("Code Block",.codeBlock,"k",[.command,.option])
        formatItem("Horizontal Rule",.horizontalRule)
        let view=submenu("View")
        add(view,"Show Sidebar",#selector(EditorWindowController.toggleSidebar(_:)),"s",[.command,.control])
        add(view,"Show Preview",#selector(EditorWindowController.togglePreview(_:)),"p",[.command,.option]);add(view,"Increase Font Size",#selector(EditorWindowController.increaseFont(_:)),"+");add(view,"Decrease Font Size",#selector(EditorWindowController.decreaseFont(_:)),"-")
        add(view,"Enter Full Screen",#selector(NSWindow.toggleFullScreen(_:)),"f",[.command,.control])
        let window=submenu("Window");NSApp.windowsMenu=window
        add(window,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m");add(window,"Zoom",#selector(NSWindow.performZoom(_:)));window.addItem(.separator());add(window,"Bring All to Front",#selector(NSApplication.arrangeInFront(_:)))
        #if DEBUG
        let help=submenu("Help");NSApp.helpMenu=help
        add(help,"Start Timing Diagnostics",#selector(toggleTimingDiagnostics(_:)))
        help.items.last?.target=self
        add(help,"Save Timing Report…",#selector(saveTimingReport(_:)))
        help.items.last?.target=self
        #endif
    }
    static var sample:String {
        guard let url = Bundle.main.url(forResource:"Example",withExtension:"md"),
              let text = try? String(contentsOf:url,encoding:.utf8) else { return shortSample }
        let imageURL = Bundle.main.url(forResource:"ExampleImage",withExtension:"png")?.absoluteString ?? ""
        return text.replacingOccurrences(of:"{{EXAMPLE_IMAGE_URL}}",with:imageURL)
    }
    private static let shortSample = #"""
    # Markato

    Native Markdown editing with a **live preview**, *styled source*, and ordinary Mac shortcuts.

    ## Tables

    | Feature | Implementation |
    | :--- | :--- |
    | Editing | AppKit and TextKit |
    | Preview | Ultralight |
    | Syntax | Comrak |

    ## Mathematics

    Inline mathematics: $E = mc^2$.

    $$
    \begin{aligned}
    a+b &= c \\
    x^2+y^2 &= z^2
    \end{aligned}
    $$

    $$
    A = \begin{pmatrix}1&2\\3&4\end{pmatrix}
    $$

    ## Code

    ```swift
    let editor = "Markato"
    ```

    - Scroll the source to keep both panes aligned.
    - Scroll the preview to inspect it independently.

    [Comrak](https://github.com/kivikakk/comrak)
    """#
}

private let launchConfiguration:LaunchConfiguration
do {launchConfiguration=try LaunchConfiguration.parse(CommandLine.arguments)}
catch {
    FileHandle.standardError.write(Data("Markato: \(error.localizedDescription)\n".utf8))
    exit(2)
}
let application = NSApplication.shared
let delegate = MainActor.assumeIsolated {AppDelegate(launchConfiguration:launchConfiguration)}
application.delegate = delegate
#if DEBUG
let backgroundCheck=(CommandLine.arguments.contains("--integration-test") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--integration-startup") || ProcessInfo.processInfo.environment["MARKATO_INTEGRATION_DEFAULT_STARTUP"] == "1")
    && !CommandLine.arguments.contains("--smoke-active-window")
application.setActivationPolicy(backgroundCheck ? .accessory:.regular)
#else
application.setActivationPolicy(.regular)
#endif
application.run()
