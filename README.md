# AstraMarkdown

A native Markdown editor for Apple Silicon Macs running macOS 15 or later. The first version uses AppKit and TextKit for editing, WebKit, markdown-it, and KaTeX for preview rendering, and Lezer for source structure and highlighting.

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

Tables and code blocks are rendered as complete semantic blocks. Table column widths do not depend on which source rows are visible, and background rendering never splits and rejoins a displayed table. The existing @mdit/plugin-tex plugin recognizes inline/display dollar delimiters and backslash parentheses/brackets; KaTeX typesets the equations, including aligned expressions and matrices. Code spans and ordinary fences remain code. Images use document-relative paths, file URLs, or HTTP/HTTPS URLs; the WebKit asset handler fetches and downsamples them asynchronously, with a 128 MiB decoded-image cache. Fonts, scripts, and styles are bundled for offline use.

Files use UTF-8 or UTF-16. Existing UTF-8 BOMs and CRLF conventions are preserved; new documents use UTF-8. NSDocument supplies normal save state, safe saving, and autosave behavior. No application-drawn modified-state label is used.

## Storage and parsing

See [the scrolling algorithm and simplification review](docs/scrolling-algorithm.md) for the human-readable design, invariants, current behavior and comparison with MacDown.

The source model is an immutable AVL tree of bounded UTF-16 chunks. Indexed edits and line lookup avoid whole-document copying. Snapshots retain shared nodes for parser jobs and saves.

The source editor retains the complete contiguous native glyph layout. Heading and image source positions come from measured line geometry rather than estimates outside a moving text window. Scrolling does not replace source text or change its coordinate frame. A measured AVL sequence indexes wrapped lines by source length and pixel height. Edits and batched syntax updates replace only affected paragraph measurements; unchanged prefix and suffix measurements remain cached, and subtree totals shift later positions. Model-driven edits and undo update the retained attributed text instead of reloading it. Width and font changes remeasure the document. Typography updates arriving during a gesture wait until it ends, and layout updates preserve the visible source anchor. Source coordinates are global. TextKit owns native selection and clipboard operations; the document model owns undo transactions. Beginning/end navigation reaches the actual document endpoints. Native layout and source memory now grow with document size; optimizing this remains separate from scroll correctness.

Lezer runs on a serial JavaScriptCore worker. Existing rope UTF-16 units cross directly into one immutable JavaScript string per revision. The worker retains its indexed syntax tree and ordered semantic blocks, reuses syntax fragments across recorded edits, and checks cancellation between resumable parse steps. Bounded tree queries supply visible highlighting runs independently of complete preview blocks. Block metadata crosses to Swift once initially and then as a changed interval; unchanged block IDs follow recorded source edits, including duplicate paragraphs. Reference collection skips inline subtrees. Parsing and block reconciliation still contain document-length-dependent work.

Foreground preparation covers the source viewport plus at least 40 source lines on either side, increasing overscan to a viewport for tall windows. The preview retains all prepared blocks at their document positions. A WKWebView sits inside a native NSClipView. Headings and standalone image tops define a piecewise-linear source-to-preview map, with document endpoints supplying boundary coordinates. Paragraphs, code blocks, and table rows do not add scrolling references; images align at their top. The alignment reference moves from the top at document start, through the midpoint, to the bottom at document end, and is incorporated into reference coordinates before interpolation. Native live-scroll notifications hold the measured map during ordinary gesture updates. Prepared content stays unchanged during a gesture. Background progress waits to publish while the current viewport is covered; only an unprepared destination may be filled during scrolling. Ending a gesture permits deferred progress. Actual content, typography and width changes rebuild the map from current measured positions; background publication never preserves old estimated source coordinates. There are no cubic tangents, image-spreading references, or continuity pins.

Every content or layout update follows one presentation pipeline. An immutable request captures HTML and source metadata, document revision, font, asset directory, and pane width. Background preparation that fills pending space entirely below the visible viewport extends the displayed DOM in place, retaining every existing rendered block and live selection. Other content or layout changes prepare a hidden surface with its own WebKit view, native clip, canvas, and asset handler; positioning it never moves the displayed document. Inactive views remain hidden throughout replacements. Both paths wait for font readiness, image loading and decoding, matching geometry, and WebKit paint incorporation before one commit publishes geometry and the ready revision; only replacements swap visibility. Stale replacement results and delayed older geometry measurements from the same revision are rejected. Unchanged text selection, focus, and horizontal reading positions are retained. Browser scroll anchoring is disabled so vertical position has one native owner. The source keeps responding while the replacement is prepared. When the displayed region no longer covers the full source viewport, the preview shows a loading state instead of presenting unrelated content as the destination. Full-context HTML comes from the syntax worker or prepared cache; partial source excerpts are never independently interpreted as documents. Scrolling inside a prepared region moves native fractional-pixel geometry without parsing Markdown, patching HTML, or issuing JavaScript scroll commands. If the source fits in its viewport but its rendering is taller, vertical input can navigate the remaining preview content; beginning/end navigation reaches its rendered endpoints. Horizontal preview gestures retain their axis through the gesture and momentum.

After the syntax tree is ready, rendering advances from top to bottom in batches. All prepared content stays in the document presentation; scrolling never prunes it to a moving window. Unprepared source intervals occupy estimated space at their document position until their actual blocks are ready. If navigation outruns rendering, the destination is prepared first while background rendering continues filling gaps. There is no document-size classification. Once preparation is complete, the whole document is mounted and scrolling performs no DOM patches. Background progress is coalesced behind an in-flight presentation, including while its WebKit shell starts, so it cannot supersede the first foreground viewport. The first prepared viewport stays visible while background rendering catches up.

Both panes share a PreparedDocument containing an ordered block index, cached highlighting coverage, measured source lines, and measured preview heights under the same block IDs and source coordinates. The worker lazily prepares complete rendering input and HTML, then reuses them across edits whenever that input is unchanged, including resolved reference definitions. Swift retains corresponding HTML and style records; style offsets shift without copying unchanged records. Background work fills only missing syntax/HTML coverage, batches source styling, and avoids republishing unchanged HTML. Each WebKit surface receives HTML only for blocks whose HTML it has not already retained; source metadata and ordering remain complete. Stale results are discarded by revision. All replacements continue through the hidden-surface geometry/resource/paint gate. The displayed DOM keeps its committed width during resize until the new layout is ready. Covered edits retain the last complete preview while their replacement prepares.

markdown-it deliberately reparses selected fragments; Lezer does not supply its token format. Both parsing and math rendering use existing libraries. Complete paragraphs, lists, quotes, and oversized cells remain intact for the agreed large-block experiment. Tables and code remain intact across viewport changes. Large units and global Markdown context changes can take more work; this implementation does not claim constant-time rendering for arbitrary edits or prove same-frame presentation at 60/120 Hz.

## Validation

```sh
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
cd Parser
npm ci
npm test
```

Native integration checks require a graphical Mac session and the separate debug app:

```sh
bash scripts/build-app.sh debug
dist/debug/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --integration-test
dist/debug/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --smoke-test
```

The integration check independently compares TextKit heading positions with DOM heading positions during continuous forward and reverse scrolling through all demo headings, including Sections 31/32 and both ends of the 800-row table at a tall window size, with a two-point tolerance. It also verifies that the first viewport appears before background rendering completes and retains the same WebView, heading position, and live selection through deliberately delayed background publication. It also verifies startup title visibility, 1,280 fractional-pixel movements near the top, exact return to zero and preservation of heading typography through partial highlighting. It verifies that the promoted WebKit surface paints the latest content, that inactive views stay hidden, that delayed geometry reports cannot overwrite committed geometry, that image traversal remains continuous in both directions, that replacement preparation leaves the old DOM intact, only the latest replacement is displayed, short-source renderings remain scrollable, selection and horizontal positions survive replacements, gesture axes remain stable, and source reloads preserve heading typography. Fast-scroll observations independently check the corresponding source passage when a prepared destination is displayed; table rows follow linear travel between sparse landmarks. A deterministic scheduler stalls top-to-bottom rendering, jumps to unprepared content, verifies foreground preparation during a gesture, then releases background batches and checks that publication waits until the covered gesture ends. It also exercises real native typing, responder-chain undo, redo, encoding, CRLF preservation, distant navigation in a 600-section document, retained measured source layout and preview content, passage preservation through repeated resizing, the current WebKit preview, synchronous clip motion without DOM changes, 600 fast-scroll coverage observations across prose, tables and images with reversals, gesture handoffs and passage alignment checks, edited preview content, local images, complete-table stability, decelerating momentum ending on a table without settling or replacement, completed background HTML preparation, and a jump to a cached destination. Failed checks report an error and exit with a nonzero status. The smoke check writes a bitmap of the example window to `/private/tmp/astra-smoke.png`.

The prototype has not established same-frame presentation at 60/120 Hz or full CommonMark compatibility. In particular, try complex nested lists and quotes, very large paragraphs and table cells, composed input, rapid scrolling, and continuous resizing. Unprepared preview intervals use estimated heights until rendered. These behaviors remain the next usability and performance measurements.

## Timing diagnostics

Timing diagnostics, native test runners, test-only counters and the stalled-rendering scheduler override are compiled only in debug builds. Release builds omit them entirely, including the JavaScript timing code. The debug app is packaged at `dist/debug/AstraMarkdown.app`, separately from `dist/AstraMarkdown.app`. Release packaging starts from a fresh allowlisted bundle and audits symbols, strings and resources with `scripts/check-release.sh`; a failed audit stops packaging. The bundled example remains a normal product resource.

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
and image preparation. A roughly 10 Hz probe samples main
queue dispatch delays. These measurements help distinguish processing delays from
discontinuous positioning; they do not measure actual displayed-frame latency.
Native intervals use a monotonic clock. JavaScript durations are reported at native
receipt and may have roughly 1 ms resolution. Nested interval totals overlap.

To include startup in a recording, launch the executable with `--diagnostics`.
The instrumented integration check verifies event collection and JSON export:

```sh
dist/debug/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --integration-test --diagnostics
```

Its report is written to `/private/tmp/astra-timings.json`. A focused `--integration-layout-index` check independently compares the cached index with native glyph coordinates after local and coalesced edits, Unicode/CRLF insertion, deletion, append, typography, resize, and model-driven replacement.

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

The complete preview regression gate runs debug and release core tests, packages and audits the release app, builds the separate debug app, and exercises native presentation, scrolling, failure, and recovery checks. Run it from a macOS graphical session:

```sh
bash Scripts/check-preview.sh
```

Presentation geometry messages are observations rather than publication commands. Superseded, malformed, unpainted, or incomplete presentations cannot commit. Font, width, HTML, metadata, and asset-directory changes use the same request identity and commit path.
