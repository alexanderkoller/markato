# AstraMarkdown

A native Markdown editor for Apple Silicon Macs running macOS 15 or later. AppKit and TextKit provide editing, Comrak supplies source structure and HTML from one Markdown parse, and WebKit displays the preview. KaTeX typesets equations.

## Build and run

Xcode with the macOS SDK, Swift 6 or later, and Rust are required to build (tested with Rust 1.96). Bundled KaTeX JavaScript is checked in; rebuilding it requires Node 22 or later. The resulting app needs neither a Rust/Node installation nor an external TeX installation.

```sh
bash scripts/build-app.sh
open dist/AstraMarkdown.app
```

The script builds the pinned Rust static library, builds the release executable, packages its JavaScript, styles, and font resources, and applies a local ad hoc signature. It does not install or publish the application. Run `bash scripts/build-native.sh` before building the Swift package directly in Xcode or with `swift build`/`swift test`.

Starting the app without another document opens a bundled example of about 135 KB, with 80 sections, local images, equations, code, an 800-row table, and a long paragraph. File → New creates a blank document. To explicitly open the example document:

```sh
dist/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --sample
```

## Editing and preview

Use the standard File and Edit menus to open and save Markdown documents, undo, redo, cut, copy, and paste. Command-F searches the whole document. Command-G and Shift-Command-G navigate results. Option-Command-P toggles the preview; Command-Plus and Command-Minus adjust font sizes.

The source owns document navigation. Vertical wheel and trackpad gestures over the preview navigate the source; tables and code scroll horizontally within the preview. Drag the divider to change pane widths. Source syntax remains literal, with colors, font traits, and heading sizes applied to it. Preview context menus offer copying and independent item inspection.

Tables and code blocks are rendered as complete semantic blocks. Table column widths do not depend on which source rows are visible. Comrak recognizes inline/display dollar delimiters, backslash parentheses/brackets and math fences; KaTeX typesets the recognized equations, including aligned expressions and matrices. Code spans and ordinary fences remain code. Images use document-relative paths, file URLs, or HTTP/HTTPS URLs; the WebKit asset handler fetches and downsamples them asynchronously, with a 128 MiB decoded-image cache. Fonts, scripts, and styles are bundled for offline use.

Files use UTF-8 or UTF-16. Existing UTF-8 BOMs and CRLF conventions are preserved; new documents use UTF-8. NSDocument supplies normal save state, safe saving, and autosave behavior. No application-drawn modified-state label is used.

## Storage and parsing

See [the scrolling algorithm and simplification review](docs/scrolling-algorithm.md) for the human-readable design, invariants, current behavior and comparison with MacDown.

The source model is an immutable AVL tree of bounded UTF-16 chunks. Indexed edits and line lookup avoid whole-document copying. Snapshots retain shared nodes for parser jobs and saves.

The source editor retains the complete contiguous native glyph layout. Heading and image source positions come from measured line geometry rather than estimates outside a moving text window. Scrolling does not replace source text or change its coordinate frame. A measured AVL sequence indexes wrapped lines by source length and pixel height. Edits and batched syntax updates replace only affected paragraph measurements; unchanged prefix and suffix measurements remain cached, and subtree totals shift later positions. Model-driven edits and undo update the retained attributed text instead of reloading it. Width and font changes remeasure the document. Typography updates arriving during a gesture wait until it ends, and layout updates preserve the visible source anchor. Source coordinates are global. TextKit owns native selection and clipboard operations; the document model owns undo transactions. Beginning/end navigation reaches the actual document endpoints. Native layout and source memory now grow with document size; optimizing this remains separate from scroll correctness.

Comrak runs on a serial native worker. Rope UTF-16 units cross directly into Rust, where they become UTF-8 without an intermediate Swift String. Each revision uses one complete Markdown parse and one formatter traversal that produces HTML and source-style records together. KaTeX receives only parser-recognized equations. A sparse Unicode/line index converts Comrak byte positions to Cocoa UTF-16 positions. The AST is freed on the worker; immutable prepared output is retained for subsequent queries. Unchanged block IDs follow recorded edits, including duplicate paragraphs, only when both source and resolved HTML match. Distant reference changes therefore invalidate consumers. Comrak does not reuse syntax trees across edits: each edit reparses the document, and stale delivery is rejected by revision/request generation.

Foreground preparation covers the source viewport plus at least 40 source lines on either side, increasing overscan to a viewport for tall windows. The preview retains all prepared blocks at their document positions. A WKWebView sits inside a native NSClipView. Headings and standalone image tops define a piecewise-linear source-to-preview map, with document endpoints supplying boundary coordinates. Paragraphs, code blocks, and table rows do not add scrolling references; images align at their top. The alignment reference moves from the top at document start, through the midpoint, to the bottom at document end, and is incorporated into reference coordinates before interpolation. Native live-scroll notifications hold the measured map during ordinary gesture updates. Prepared content stays unchanged during a gesture. Native typography batches wait until the gesture ends. Actual content, typography and width changes rebuild the map from current measured positions; background publication never preserves old estimated source coordinates. There are no cubic tangents, image-spreading references, or continuity pins.

Every content or layout update follows one presentation pipeline. An immutable request captures HTML and source metadata, document revision, font, asset directory, and pane width. Broad content or layout changes prepare a hidden surface with its own WebKit view, native clip, canvas, and asset handler; positioning it never moves the displayed document. A small edit whose parser manifest has a retained prefix and suffix instead patches the corresponding block on the displayed full-document DOM and shifts suffix source metadata once. It still measures complete geometry and commits the new scroll map atomically. Presentations wait for font readiness, image loading and decoding, and matching geometry; hidden replacements also wait for WebKit paint incorporation before swapping visibility. Stale replacement results and delayed older geometry measurements from the same revision are rejected. Unchanged text selection, focus, and horizontal reading positions are retained. Browser scroll anchoring is disabled so vertical position has one native owner. The source keeps responding while the replacement is prepared. When the displayed region no longer covers the full source viewport, the preview shows a loading state instead of presenting unrelated content as the destination. Full-context HTML comes from the syntax worker or prepared cache; partial source excerpts are never independently interpreted as documents. Scrolling inside a prepared region moves native fractional-pixel geometry without parsing Markdown, patching HTML, or issuing JavaScript scroll commands. If the source fits in its viewport but its rendering is taller, vertical input can navigate the remaining preview content; beginning/end navigation reaches its rendered endpoints. Horizontal preview gestures retain their axis through the gesture and momentum.

The first presentation waits for the entire revision's parse and HTML conversion. It contains the whole document, without pending regions or provisional Markdown. Scrolling queries cached content and performs no additional parsing or HTML rendering. Source typography outside the viewport is applied in native batches after first publication; these batches defer during a gesture and never publish new HTML.

Both panes share a PreparedDocument containing an AVL block sequence, an interval index of complete source-style records, measured source lines and measured preview heights under the same block IDs and source coordinates. After every full Comrak parse, its manifest identifies the unchanged prefix and suffix. The document splices only the changed middle, lazily shifts suffix coordinates and retains cached HTML, syntax, source measurements and preview heights on both sides. The interval index selects viewport styles without scanning every span in a giant table. Inserted text inherits the prepared style at its edit point, and Comrak corrects it if the edit changes syntax. TextKit measures only affected paragraphs and the retained line tree supplies the unchanged suffix height. A local WebKit patch transmits only changed blocks plus the suffix shift; broad invalidation continues through the hidden-surface geometry, resource and paint gate. The displayed DOM keeps its committed width during resize until the new layout is ready.

The Comrak adapter preserves complete paragraphs, lists, quotes, tables and code across viewport changes. Source delimiter styling is derived from parser-recognized source ranges, rather than another Markdown parser. Full parsing and the mounted DOM still grow with document size; edit-time record transfer, tree updates and local DOM updates grow with the changed interval. The preserved pre-port builds and benchmark records are under `research/2026-10-10/comrak-port/baseline`; the retained-tree comparison is documented in `research/2026-10-10/comrak-audit/retained-edit-results.md`.

## Validation

```sh
bash scripts/build-native.sh
cargo test --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak
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

The integration check compares measured TextKit and DOM heading positions during forward and reverse scrolling, including long tables and images. It verifies full-document HTML in the first presentation, cached deep navigation without reparsing, and geometry preservation while delayed source typography waits for a gesture to end. It also exercises native typing and undo/redo, Unicode and CRLF, selection, resize, horizontal gestures, stale presentation rejection, hidden-surface paint readiness, asset loading, and the source layout index. Failed checks exit with a nonzero status. The smoke check writes a bitmap of the example window to `/private/tmp/astra-smoke.png`.

The prototype has not established same-frame presentation at 60/120 Hz or complete behavior equivalence with the earlier Markdown dialect. In particular, try complex nested lists and quotes, very large paragraphs and table cells, composed input, rapid scrolling and continuous resizing.

## Timing diagnostics

Timing diagnostics, native test runners, test-only counters and the stalled-typography scheduler override are compiled only in debug builds. Release builds omit them entirely, including the JavaScript timing code. The debug app is packaged at `dist/debug/AstraMarkdown.app`, separately from `dist/AstraMarkdown.app`. Release packaging starts from a fresh allowlisted bundle and audits symbols, strings and resources with `scripts/check-release.sh`; a failed audit stops packaging. The bundled example remains a normal product resource.

Choose **Help → Start Timing Diagnostics**, reproduce the scrolling or editing problem,
then choose **Help → Stop Timing Diagnostics** and **Help → Save Timing Report…**.
Starting another recording clears the previous one. Recording is off by default;
the most recent 20,000 completed events are retained in memory, with no file I/O
on scrolling callbacks. The exported JSON includes a timestamped event timeline,
counts, medians, p95/max durations, queue delays, source/preview positions, cache
and viewport sizes, and system/app metadata. It contains no document text or file
paths. Exporting a report does not stop an active recording.

Measurements distinguish source layout/highlighting, viewport preparation, cache
updates, worker queue waits, Comrak/input/record work, KaTeX, WebKit round trips, DOM patch/layout,
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

Comrak 0.55.0 is vendored with a small source-coordinate correction documented in `Native/vendor/comrak/ASTRA-PATCH.md`. The Rust dependency versions are pinned in `Native/Comrak/Cargo.lock`. Build the native adapter with `bash scripts/build-native.sh`. The bundled KaTeX JavaScript and third-party notices are checked in. To rebuild KaTeX after changing `Parser/math.mjs`:

```sh
cd Parser
npm ci
npm run build
```

The application has no external Swift dependencies. Node library versions are pinned in package-lock.json. Comrak, Rust dependency and KaTeX license notices are packaged in the application. Earlier library experiments remain under `research/2026-10-05`.

The complete preview regression gate runs debug and release core tests, packages and audits the release app, builds the separate debug app, and exercises native presentation, scrolling, failure, and recovery checks. Run it from a macOS graphical session:

```sh
bash scripts/check-preview.sh
```

Presentation geometry messages are observations rather than publication commands. Superseded, malformed, unpainted, or incomplete presentations cannot commit. Font, width, HTML, metadata, and asset-directory changes use the same request identity and commit path.
