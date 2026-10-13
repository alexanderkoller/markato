# File menu, export, printing, and Close All

## Goal

Give Markato a conventional document-oriented File menu, add useful rendered
output without weakening the performance architecture of the live preview, and
make **Close All** (`Shift-Command-W`) safe for edited documents.

## Existing capabilities

Markato currently exposes these File menu commands:

- New, Open, Close
- Save, Save As, Revert to Saved

The document layer reads and writes Markdown in UTF-8 or UTF-16 and preserves a
UTF-8 BOM and the document's newline convention. There is no product-level HTML,
PDF, print, plain-text, rich-text, image, or sharing command.

The rendering pipeline nevertheless provides most of what an HTML exporter
needs:

- `ComrakWorker` produces ordered HTML for every top-level block in a complete
  document parse.
- The generated HTML already contains rendered KaTeX, syntax-highlighted code,
  and Mermaid diagrams represented as data-URL SVG images.
- `HTMLPreviewView` bundles the KaTeX, preview, and code-highlight stylesheets.
- The preview resolves `astra-asset:` image placeholders relative to the
  Markdown document and embeds local images as data URLs.

These pieces are private to the live preview today. The preview itself is not a
print surface: it mounts a bounded window of document blocks and renders a
viewport bitmap. Printing that view would omit offscreen content or turn a long
document into a large raster image.

Debug builds can export timing diagnostics as JSON. The integration harness can
capture PNG screenshots, but neither is a user document-export feature.

## Proposed File menu

The first release should use direct commands instead of an Export submenu. Two
formats are easy to scan, and PDF is also a familiar top-level macOS File menu
command.

```text
New                              Command-N
Open…                           Command-O
Open Recent                    >
------------------------------------------
Close                            Command-W
Close All Windows          Shift-Command-W
------------------------------------------
Save                             Command-S
Save As…                  Shift-Command-S
Revert to Saved…
------------------------------------------
Export as HTML…
Export as PDF…
------------------------------------------
Print…                           Command-P
```

`Open Recent` is included because `NSDocumentController` already owns recent
document tracking and users will expect it once the File menu grows. It can be
omitted from the first implementation without affecting export or Close All.

Do not add **Export as Plain Text**: Markdown is already an ordinary text file,
so Save As provides the useful behavior without inventing a lossy duplicate.
RTF/RTFD, DOCX, EPUB, and image export should wait for concrete use cases. They
either lose Markdown semantics, require a new conversion dependency, or perform
poorly for long documents. A future **Share** submenu can share the Markdown
source, but it is separate from rendered export.

## Export as HTML

### User-visible behavior

- The save panel proposes `<document name>.html`, or `Untitled.html`.
- The output is one portable HTML file. Local images and Mermaid diagrams are
  embedded; remote images remain remote URLs.
- The file includes the same typography, math, code highlighting, tables, and
  diagram styling as the preview.
- Export captures the document revision that existed when the command was
  invoked. Later edits do not silently change an export already in progress.
- Exporting does not mark the Markdown document as saved or change its file URL.

### Implementation shape

Introduce a `RenderedDocumentBuilder` outside `HTMLPreviewView`. It should own:

1. full-document Markdown rendering from an immutable rope/revision snapshot;
2. ordered block assembly;
3. stylesheet loading;
4. `astra-asset:` resolution; and
5. construction of a complete HTML document with escaped title and metadata.

Use a dedicated `ComrakWorker` for an export. Reusing the live document worker
would increment its request generation, allowing an export and an interactive
preview request to cancel one another.

Move the current private asset resolver into shared code. For HTML export, embed
readable local images as data URLs, preserve `http` and `https` image URLs, and
leave a broken reference visible when a local image cannot be read. Put a
restrictive Content Security Policy in the generated document so raw Markdown
HTML cannot turn a saved export into an executable-script container. Inline
styles and data images must remain allowed; scripts, plugins, frames, and network
connections should be blocked.

Keep export-specific page CSS separate from preview virtualization rules. The
HTML can reuse content styles, but should not depend on `#preview` positioning,
paint containment, or mounted-section bookkeeping.

## Print and Export as PDF

Print and PDF should be two front ends to the same paginated rendering path. That
guarantees that **Export as PDF** matches the print preview and avoids maintaining
two layout implementations.

Create an on-demand `WKWebView` print renderer in a small helper process:

1. Ask `RenderedDocumentBuilder` for the same complete, self-contained HTML.
2. Add print CSS: a white canvas, printable margins, sensible page-break rules,
   repeated table headers where supported, and avoidance of breaks inside code,
   images, equations, and Mermaid diagrams when they fit on one page.
3. Load the HTML and wait for navigation, fonts, and embedded images to settle.
4. Capture page-sized vector PDF segments and assemble them into one paginated
   PDF using PDFKit.
5. For **Print**, show the standard print panel first, render using its selected
   paper and margins, then submit the resulting PDF without showing a second
   panel.
6. For **Export as PDF**, atomically copy the same rendered PDF to the URL
   selected by a save panel.

WebKit is a system framework on the supported macOS versions and is only used
when the user asks for printable output. It must not be loaded into Markato's
process because WebKit and Ultralight both contain a WebCore library; mixing the
two produces Objective-C class collisions. The helper keeps WebKit isolated,
while the interactive preview remains on Ultralight and keeps its current
startup and scrolling behavior.

The helper retains its hidden web view until navigation and page capture finish.
The document coordinator retains and terminates the helper with the document,
reports load/print errors as a sheet, and serializes output jobs per document.
Commands are disabled while that document already has an output job in progress.

The standard Print panel owns paper size, orientation, and scaling. A separate
Page Setup command is unnecessary unless Markato later adds persistent
document-specific settings such as custom margins, headers, or page numbering.

## Close All

### Semantics

**Close All** closes every open Markato document, not arbitrary application or
utility windows. Markato remains running with no windows, matching the existing
`applicationShouldTerminateAfterLastWindowClosed` behavior. Clicking the Dock
icon after that creates a new untitled document through the existing reopen path.

Use `NSDocumentController.closeAllDocuments(...)`, not a loop over windows. The
document controller already asks every edited `NSDocument` whether it can close,
offers Save / Don't Save / Cancel, waits for asynchronous saves, and stops after
a cancellation or save failure. This also ensures each successful close removes
the document from `NSDocumentController` correctly.

The operation has standard sequential semantics: if earlier documents have
already closed and the user cancels a later prompt, the earlier closes are not
rolled back. Do not close unreviewed edited documents or bypass
`canCloseDocument`.

### Menu routing and validation

- Add an AppDelegate `closeAllDocuments(_:)` action and route the menu item to
  it explicitly.
- Assign `Shift-Command-W` exactly as requested.
- Enable the item when `NSDocumentController.shared.documents` is nonempty and
  no Close All operation is already in progress.
- Disable the item during its asynchronous close sequence to prevent reentry.
- Keep ordinary **Close** on `NSWindow.performClose(_:)`; it should continue to
  use normal `NSDocument` unsaved-change handling for the active window.

## Error and cancellation rules

- Canceling an HTML or PDF save panel has no side effects.
- A parse, asset, web-load, or print failure leaves the Markdown document open
  and unchanged and presents one actionable error sheet.
- If the source changes during rendering, finish the explicitly captured
  snapshot; do not restart indefinitely. The progress UI can say which document
  is being exported but need not expose revision numbers.
- Export writes to a temporary sibling file and atomically replaces the chosen
  destination only after successful completion.
- Remote images should have a bounded wait for Print/PDF. A timeout prints a
  visible missing-image placeholder rather than hanging the command.

## Verification without UI automation

Repository policy rules out computer control. Cover this feature with
command-line tests and purpose-built harnesses:

- Unit-test complete HTML assembly, title escaping, block order, CSP, styles,
  Unicode, local/remote image handling, missing assets, KaTeX, highlighted code,
  raw HTML, and Mermaid data URLs.
- Add an integration flag that exports a fixture to HTML at a supplied path and
  validates its contents without opening a panel.
- Add a print/PDF integration flag that accepts a destination and print settings,
  waits for the offscreen renderer, writes a PDF, and checks it with PDFKit for
  page count and extractable text. Include a document long enough to span pages.
- Unit-test Close All's enabled/reentry state around an injected document-closing
  service. In the application harness, open multiple clean documents, dispatch
  the real menu action, and assert that the document and window counts reach
  zero.
- Keep prompt-specific Save / Don't Save / Cancel behavior delegated to AppKit;
  verify Markato does not override or bypass `NSDocument` close handling.

## Delivery order

1. Add Close All and its command-line integration check.
2. Extract shared full-document HTML assembly and ship Export as HTML.
3. Add the offscreen paginated renderer, then ship Print and Export as PDF
   together.
4. Add Open Recent and later formats only when their behavior is justified.

