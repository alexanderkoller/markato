# AstraMarkdown

A native Markdown editor for Apple Silicon Macs running macOS 15 or later. The first version uses AppKit and TextKit 2 for editing, WebKit, markdown-it, and KaTeX for preview rendering, and Lezer for source structure and highlighting.

## Build and run

Xcode with the macOS SDK and Swift 6 or later is required to build. Bundled JavaScript is checked in; changing it also requires Node 22 or later for the parser build step. The resulting app needs neither Node nor an external TeX installation.

```sh
bash scripts/build-app.sh
open dist/AstraMarkdown.app
```

The script builds a release executable, packages its JavaScript, styles, and font resources, and applies a local ad hoc signature. It does not install or publish the application. Open the Swift package in Xcode to work on the source.

Starting the app without another document opens a bundled example of about 135 KB, with 80 sections, local images, equations, code, an 800-row table, and a long paragraph. File → New creates a blank document. To explicitly open the example document:

```sh
dist/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --sample
```

## Editing and preview

Use the standard File and Edit menus to open and save Markdown documents, undo, redo, cut, copy, and paste. Command-F searches the whole document. Command-G and Shift-Command-G navigate results. Option-Command-P toggles the preview; Command-Plus and Command-Minus adjust font sizes.

The source owns document navigation. Vertical wheel and trackpad gestures over the preview navigate the source; tables and code scroll horizontally within the preview. Drag the divider to change pane widths. Source syntax remains literal, with colors, font traits, and heading sizes applied to it. Preview context menus offer copying and independent item inspection.

Tables use markdown-it with a header and selected rows. Adjacent cached row batches are joined into one DOM table with shared columns and one header; cache boundaries do not introduce visible pagination. The existing @mdit/plugin-tex plugin recognizes inline/display dollar delimiters and backslash parentheses/brackets; KaTeX typesets the equations, including aligned expressions and matrices. Code spans and ordinary fences remain code. Images use document-relative paths, file URLs, or HTTP/HTTPS URLs; the WebKit asset handler fetches and downsamples them asynchronously, with a 128 MiB decoded-image cache. Fonts, scripts, and styles are bundled for offline use.

Files use UTF-8 or UTF-16. Existing UTF-8 BOMs and CRLF conventions are preserved; new documents use UTF-8. NSDocument supplies normal save state, safe saving, and autosave behavior. No application-drawn modified-state label is used.

## Storage and parsing

The source model is an immutable AVL tree of bounded UTF-16 chunks. Indexed edits and line lookup avoid whole-document copying. Snapshots retain shared nodes for parser jobs and saves.

The TextKit adapter materializes a working window around the source viewport rather than a full attributed document. Its line budget grows with viewport height. When replenishing the working window, it preserves the actual visible source anchor and pixel displacement; whole-document estimates are reserved for navigation outside the laid-out window. Global source positions, caret state, undo transactions, and clipboard operations belong to the document model. Command-Up/Down navigates to the actual document beginning/end, rather than the local text window; the end canvas uses the measured final layout. A selection spanning more text can expand the working set. Global scrollbar geometry uses estimates; the active window uses native TextKit layout. This implementation uses a bounded NSTextContentStorage working set instead of implementing a new NSTextContentManager subclass.

Lezer runs on a serial JavaScriptCore worker against a chunk-input bridge. It reuses syntax fragments across recorded edits, checks cancellation between resumable parse steps, and returns only viewport syntax and preview fragments to Swift. It still has document-length-dependent tree bookkeeping and reference-index rebuilding on the worker. Coalescing work avoids treating background parsing as an O(log N) guarantee.

The preview mounts only the source viewport plus roughly 20 lines above and 40 below. A WKWebView sits inside a native NSClipView. Source bounds changes position that clip synchronously by interpolating between headings and standalone images, following MacDown's sparse landmark approach. The passage at the viewport midpoint is the alignment reference; this tapers toward the document edges. Landmark coordinates are captured at the start of a scroll gesture and retained through momentum. Source working-window shifts and preview remounts translate their coordinate origins without replacing captured distances. Newly exposed landmarks can extend the frozen region. A mounted region without headings or images, such as a table row window, uses its two edges as fallback landmarks. Other lines can have different vertical positions because source and rendered block heights differ. Scrolling within the prepared region does not parse Markdown, patch the DOM, or issue JavaScript scroll commands. Landmark positions refresh outside gestures; edits, navigation, and resizing release the snapshot. Displayed geometry remains paired with its own block set until a replacement has been measured, and highlighting preserves the visible source anchor. At the document end, the preview transitions to bottom alignment so its final line remains fully visible. Width changes reflow only mounted HTML. WebKit reports local geometry after content, fonts, or images change.

HTML preparation runs in JavaScriptCore workers. A separate local worker produces provisional visible HTML without waiting for a whole-document Lezer parse; it is corrected when full source context is available. Cold jumps use that path when HTML is not cached. Provisional excerpts can temporarily lack enclosing list/fence context or distant reference definitions.

After the syntax tree is ready, background preparation renders 100-source-line batches and retains their HTML outside the DOM. A 64 MiB HTML/source cache uses an AVL interval index with stable fragment IDs and lazy suffix offset shifts. Ordinary edits invalidate local cached pages; contiguous cached subtrees are skipped while repairing gaps. Delimiter or reference-definition changes conservatively invalidate cached document context. Stale background batches are discarded by revision. The live DOM receives only changed HTML and keeps unaffected elements. Cached HTML is independent of pane width; there is no whole-document preview layout or cumulative preview height index.

markdown-it deliberately reparses selected fragments; Lezer does not supply its token format. Both parsing and math rendering use existing libraries. Complete paragraphs, lists, quotes, and oversized cells remain intact for the agreed large-block experiment. Tables and code use source windows. Large units and global Markdown context changes can take more work; this implementation does not claim constant-time rendering for arbitrary edits or prove same-frame presentation at 60/120 Hz.

## Validation

```sh
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
cd Parser
npm ci
npm test
```

Native integration checks require a graphical Mac session:

```sh
dist/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --integration-test
dist/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --smoke-test
```

The integration check exercises real native typing, responder-chain undo, redo, encoding, CRLF preservation, distant navigation in a 6,000-section document, bounded working sets, passage preservation through repeated resizing, the current WebKit preview, synchronous clip motion without DOM changes, edited preview content, local images, table row windows, completed background HTML preparation, and a jump to a cached destination. Failed checks report an error and exit with a nonzero status. The smoke check writes a bitmap of the example window to `/private/tmp/astra-smoke.png`.

The prototype has not established same-frame presentation at 60/120 Hz or full CommonMark compatibility. In particular, try complex nested lists and quotes, very large paragraphs and table cells, composed input across working-set changes, rapid scrolling, and continuous resizing. Source geometry is estimated outside the current window, and table column widths can change as selected rows change. These behaviors remain the next usability and performance measurements.

## Timing diagnostics

Choose **Help → Start Timing Diagnostics**, reproduce the scrolling or editing problem,
then choose **Help → Stop Timing Diagnostics** and **Help → Save Timing Report…**.
Starting another recording clears the previous one. Recording is off by default;
the most recent 20,000 completed events are retained in memory, with no file I/O
on scrolling callbacks. The exported JSON includes a timestamped event timeline,
counts, medians, p95/max durations, queue delays, source/preview positions, cache
and viewport sizes, and system/app metadata. It contains no document text or file
paths. Exporting a report does not stop an active recording.

Measurements distinguish source layout/highlighting, viewport preparation, cache
updates, worker queue waits, Lezer/HTML work, WebKit round trips, DOM patch/layout,
image preparation, and native clip movement. A roughly 10 Hz probe samples main
queue dispatch delays. These measurements help distinguish processing delays from
discontinuous positioning; they do not measure actual displayed-frame latency.
Native intervals use a monotonic clock. JavaScript durations are reported at native
receipt and may have roughly 1 ms resolution. Nested interval totals overlap.

To include startup in a recording, launch the executable with `--diagnostics`.
The instrumented integration check verifies event collection and JSON export:

```sh
dist/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --integration-test --diagnostics
```

Its report is written to `/private/tmp/astra-timings.json`.

The [6 October performance profile](research/2026-10-06/performance/README.md)
records CPU samples, before/after timing comparisons, the duplicate-highlighting
fix, and the remaining optimization candidates.

## Parser maintenance

The bundled JavaScript and third-party notices are checked in. To rebuild the parser after changing `Parser/lezer.mjs`:

```sh
cd Parser
npm ci
npm run build
```

The application has no external Swift dependencies. Node library versions are pinned in package-lock.json. Third-party license notices are packaged in the application. Earlier library experiments remain under `research/2026-10-05`.
