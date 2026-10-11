import AppKit
import MarkdownCore
import UniformTypeIdentifiers

#if DEBUG
@_cdecl("astra_timing_start")
func startProfileRecording() { TimingDiagnostics.shared.start() }
@_cdecl("astra_timing_export")
func exportProfileRecording(_ path:UnsafePointer<CChar>) {
    try? TimingDiagnostics.shared.snapshot().json().write(to:URL(fileURLWithPath:String(cString:path)))
}
#endif

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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
    @objc func togglePreview(_ sender:Any?) { currentEditor?.togglePreview(sender) }
    @objc func increaseFont(_ sender:Any?) { currentEditor?.increaseFont(sender) }
    @objc func decreaseFont(_ sender:Any?) { currentEditor?.decreaseFont(sender) }
    @objc func saveDocument(_ sender:Any?) { (currentEditor?.document as? NSDocument)?.save(sender) }
    @objc func saveDocumentAs(_ sender:Any?) { (currentEditor?.document as? NSDocument)?.saveAs(sender) }
    @objc func revertDocumentToSaved(_ sender:Any?) { (currentEditor?.document as? NSDocument)?.revertToSaved(sender) }
    #if DEBUG
    @objc func toggleTimingDiagnostics(_ sender:Any?) {
        if TimingDiagnostics.shared.isRecording {TimingDiagnostics.shared.stop()}
        else {TimingDiagnostics.shared.start()}
    }
    @objc func saveTimingReport(_ sender:Any?) {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json]
        panel.nameFieldStringValue="AstraMarkdown Timings.json"
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
        #else
        let checking=false
        #endif
        NSWindow.allowsAutomaticWindowTabbing = true
        buildMenus()
        if NSDocumentController.shared.documents.isEmpty || CommandLine.arguments.contains("--sample") || checking {
            let document = MarkdownDocument(); document.setInitialText(Self.sample)
            NSDocumentController.shared.addDocument(document); document.makeWindowControllers()
            #if DEBUG
            if checking {document.windowControllers.first?.window?.setFrameOrigin(NSPoint(x:-10000,y:0))}
            document.showWindows()
            if CommandLine.arguments.contains("--integration-test") { DispatchQueue.main.asyncAfter(deadline:.now()+1) { IntegrationCheck.run(document) } }
            if CommandLine.arguments.contains("--smoke-test") {
                DispatchQueue.main.asyncAfter(deadline:.now()+3) {
                    guard let window = document.windowControllers.first?.window,let view = window.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { exit(2) }
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/private/tmp/astra-smoke.png"))
                    print("SMOKE: windows=\(NSApp.windows.count), nativeGlyphLayout=\((document.windowControllers.first as? EditorWindowController)?.source.textView.layoutManager != nil), previewRevision=\((document.windowControllers.first as? EditorWindowController)?.preview.lastRevision ?? -1)")
                    print((document.windowControllers.first as? EditorWindowController)?.preview.debugGeometry() ?? "No preview")
                    exit(EXIT_SUCCESS)
                }
            }
            #else
            document.showWindows()
            #endif
        }
        if !checking {NSApp.activate(ignoringOtherApps:true)}
    }
    func applicationShouldOpenUntitledFile(_ sender:NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    private func buildMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        func submenu(_ title:String)->NSMenu { let item=NSMenuItem(); item.title=title;let menu=NSMenu(title:title);item.submenu=menu;main.addItem(item);return menu }
        func add(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String="",_ modifiers:NSEvent.ModifierFlags = .command) {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.keyEquivalentModifierMask=modifiers
            let routed:Set<String> = ["undo:","redo:","showFind:","findNext:","findPrevious:","togglePreview:","increaseFont:","decreaseFont:","saveDocument:","saveDocumentAs:","revertDocumentToSaved:"]
            if routed.contains(NSStringFromSelector(action)) { item.target = self }
            if action == #selector(NSDocumentController.newDocument(_:)) || action == #selector(NSDocumentController.openDocument(_:)) { item.target = NSDocumentController.shared }
            menu.addItem(item)
        }
        let app=submenu("AstraMarkdown")
        add(app,"About AstraMarkdown",#selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator());let services=NSMenuItem(title:"Services",action:nil,keyEquivalent:"");services.submenu=NSMenu();app.addItem(services);NSApp.servicesMenu=services.submenu
        app.addItem(.separator());add(app,"Hide AstraMarkdown",#selector(NSApplication.hide(_:)),"h");add(app,"Hide Others",#selector(NSApplication.hideOtherApplications(_:)),"h",[.command,.option]);add(app,"Show All",#selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator());add(app,"Quit AstraMarkdown",#selector(NSApplication.terminate(_:)),"q")
        let file=submenu("File")
        add(file,"New",#selector(NSDocumentController.newDocument(_:)),"n");add(file,"Open…",#selector(NSDocumentController.openDocument(_:)),"o")
        file.addItem(.separator());add(file,"Close",#selector(NSWindow.performClose(_:)),"w");add(file,"Save",#selector(NSDocument.save(_:)),"s");add(file,"Save As…",#selector(NSDocument.saveAs(_:)),"s",[.command,.shift])
        add(file,"Revert to Saved…",#selector(NSDocument.revertToSaved(_:)))
        let edit=submenu("Edit")
        add(edit,"Undo",#selector(EditorWindowController.undo(_:)),"z");add(edit,"Redo",#selector(EditorWindowController.redo(_:)),"z",[.command,.shift]);edit.addItem(.separator())
        add(edit,"Cut",#selector(NSText.cut(_:)),"x");add(edit,"Copy",#selector(NSText.copy(_:)),"c");add(edit,"Paste",#selector(NSText.paste(_:)),"v");add(edit,"Select All",#selector(NSText.selectAll(_:)),"a")
        edit.addItem(.separator());add(edit,"Find…",#selector(EditorWindowController.showFind(_:)),"f");add(edit,"Find Next",#selector(EditorWindowController.findNext(_:)),"g");add(edit,"Find Previous",#selector(EditorWindowController.findPrevious(_:)),"g",[.command,.shift])
        let view=submenu("View")
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
    # AstraMarkdown

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
    let editor = "AstraMarkdown"
    ```

    - Source owns scrolling.
    - Preview follows the visible passage.

    [Comrak](https://github.com/kivikakk/comrak)
    """#
}

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated {AppDelegate()}
application.delegate = delegate
#if DEBUG
application.setActivationPolicy(CommandLine.arguments.contains("--integration-test") || CommandLine.arguments.contains("--smoke-test") ? .accessory:.regular)
#else
application.setActivationPolicy(.regular)
#endif
application.run()
