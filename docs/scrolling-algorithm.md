# How synchronized scrolling works

This describes AstraMarkdown's implementation on 11 October 2026. It covers the main editor and its synchronized bounded Ultralight preview. The separate table inspector has its own row-window behavior.

The central rule is simple: **scrolling moves through a document that is already laid out. It does not change that document.** If rendering has not reached the destination, preparing that missing content is a separate operation.

## The intended simple design

The implementation has **one committed presentation, one viewport map, and three operations**.

A committed presentation contains the content revision, layout identity, prepared source coverage, measured source and preview geometry, and the map constructed from those measurements. The layout identity changes when width, typography, asset context or actual resource layout changes. These values describe one coherent presentation. A pending update is separate; it cannot gradually overwrite committed geometry while asynchronous work is unfinished.

### Operation A: prepare content

Prepare missing blocks, in source order by default and at the requested destination when navigation outruns progress. Store the result with its content revision. Preparation may run while the user scrolls. It does not itself authorize changing the visible document.

Applied source highlighting has coverage too. Receiving spans is different from applying them: spans deferred during a gesture cannot count as already applied. Once both content and highlighting cover the document, moving the viewport has no reason to invoke the parser again.

### Operation B: move the viewport

Read the native source scroll origin, evaluate the committed map, and move the native preview clip to the resulting origin. Check whether the destination is covered. That is the entire prepared-scroll operation.

The map uses measured heading and standalone image-top pairs plus document endpoints, a specified boundary-alignment rule, and linear interpolation. Its calculation has no history-dependent correction, row-specific rule or velocity filter. The same source position with the same committed presentation produces the same preview position, regardless of direction, previous scrolls or input speed.

When the source has no scrollable range but the preview does, the preview can be read independently. This follows from unequal scroll domains; it is a general boundary case rather than an exception for tables or images.

### Operation C: publish a coherent update

Publish only for actual new content or changed layout. Check that the content revision and layout identity are still current, resources have settled, geometry is measured, and the destination has been painted. Construct the map from that geometry, then commit the presentation together.

The preview keeps two Ultralight surfaces. An addition that overlaps the current bounded window updates its keyed DOM nodes in place. A change that cannot be committed coherently on the visible surface prepares the spare surface and publishes the complete presentation atomically.

During a covered gesture, publication and layout-changing source typography wait. An unprepared destination may be published during a gesture because genuinely new content is required. Until then, show loading instead of unrelated material. A gesture boundary by itself never requests a new presentation or a corrective animation.

### Invariants that define correctness

| Invariant | Observable consequence |
|---|---|
| **One vertical owner.** Native clip geometry owns vertical position. | Browser scrolling or anchoring cannot shift the preview independently. |
| **One coordinate system per document layout.** Source positions are measured in a retained native layout. | Scrolling does not replace source windows, rebase coordinates or substitute distant estimates. |
| **One coherent committed presentation.** Coverage, geometry and map belong to the same content/layout identity. | An older asynchronous result cannot overwrite a newer presentation, and pending geometry cannot masquerade as committed geometry. |
| **A map is a pure, continuous, monotone function.** Matching references agree at the reading reference; endpoints agree at document boundaries. | Reversing direction retraces the same positions; forward input never causes backward preview motion. Gain is constant inside each interval. |
| **Prepared viewport movement is read-only.** It changes viewport positions, not document content or layout. | No parser requests, source restyling, DOM patches, resource reloads or view swaps occur solely because prepared content enters or leaves view. |
| **A covered gesture holds its presentation geometry.** Preparation may advance privately. | Momentum cannot trigger an asynchronous change of gain or a jump after stopping. Missing-destination publication is the explicit content-change case. |
| **Unprepared content is identified by coverage.** Classification never depends on document size. | The same preparation rule handles a short cold document and a long partially rendered one. |
| **First visibility persists through unchanged background progress.** Existing visible content remains intact. | Startup cannot show the first viewport, hide it for unrelated additions, then show it again. |

Measured-coordinate agreement must be checked independently of the implementation's map. A “zero drift” result calculated from that same map proves only that the clip followed the map. Missing or incompatible measurements should prevent a new presentation from being accepted as measured; they should not silently become an estimated distant position.

These invariants are stronger than “it feels smooth in a fixture.” They constrain the implementation and provide specific tests. They also explain which complexity is necessary: revisions protect asynchronous results; coverage protects unprepared navigation; publication protects visible content. Source-window rebasing and repeated prepared-content parsing have no role in this design.

## What “aligned” means

The two panes have different layouts. Markdown punctuation disappears in the preview, paragraphs wrap differently, images become taller than their source markup, and table rows have different heights. Equal scroll distances or equal percentages of document height therefore do not keep the same passage in view.

Instead, we match a few recognizable places in both documents. In the interior of a long document, the reading reference is the middle of the pane. When a heading reaches that reference in the editor, the corresponding rendered heading should reach it in the preview. Near the beginning and end, the reference changes so both documents can reach their actual endpoints.

This does not make every visible heading appear at the same height simultaneously. Different amounts of material can lie between two headings in the two layouts. Nor does it promise exact correspondence for every intermediate table row. The agreement is at the landmarks, with continuous interpolation between them.

## 1. Keep stable document coordinates

The editor retains the complete source document in an `NSTextView` backed by `NSLayoutManager`. It prepares the full contiguous glyph layout after edits, styling, font changes or resizing. Its vertical positions come from native line layout, including wrapping and heading typography. Measured line ranges and rectangles are indexed once during preparation; viewport and landmark queries use binary searches in that index without asking TextKit to lay out anything. The source canvas height comes from measured glyph layout bounds, including the final empty line. The editor owns the text view and canvas dimensions; native automatic resizing is disabled. Scrolling does not load a different source window, regenerate the index or change document coordinates.

The retained document tree caches every prepared Markdown block in document order. The HTML engine mounts only a bounded window, normally about 24 viewports, selected from that cache. Stable block IDs preserve overlapping DOM nodes when the window moves. Consequently, cache completion does not turn into a whole-document HTML layout.

Measurements are necessary because a character offset identifies a place in the text, but does not say how far down the pane it appears. The old moving source window estimated distant positions. Freezing those estimates could preserve a smooth but incorrect mapping. The current algorithm uses actual source layout instead.

## 2. Choose sparse landmarks

The content landmarks are:

- Headings, using the top of the rendered heading and the native source line position.
- Standalone images, using the rendered image's top and the source position of its markup.

The HTML module recognizes a direct heading inside a rendered section, or an image that is the sole element in an otherwise text-free paragraph. The parser supplies source positions and stable block identities, so the corresponding source and rendered positions can be paired without page JavaScript.

Paragraphs, list items, code lines, table starts, table rows and image bottoms do not add content landmarks. Document boundaries supply the start and end of the scrolling domain. There are always global document endpoints. Pending intervals describe rendering coverage; they do not introduce extra map endpoints.

Consequently, a heading immediately above a table is a landmark. An 800-row table does not introduce 800 additional landmarks. Its height contributes to the distance between the surrounding landmarks.

## 3. Turn landmark positions into viewport positions

A landmark's document position is different from the scroll position that puts it at the reading reference. For example, a heading 1,300 points down the source appears at the middle of a 600-point pane when the source viewport starts at 1,000 points.

We make that conversion once when constructing the map:

1. Choose the reading-reference offset for the source viewport position.
2. Find the source viewport origin that places the landmark at that offset.
3. Subtract the same offset from the rendered landmark's position to obtain the corresponding preview viewport origin.

At the document top the reference offset is zero. In the interior it is half the viewport height. At the bottom it becomes the full viewport height. The transitions occur over a band of up to one viewport at each end; shorter scrollable documents use shorter bands. Explicit boundary points pair source zero with preview zero, and the source's maximum scroll origin with the preview's maximum scroll origin.

The implementation inverts this three-piece linear rule directly. It handles a source with no scroll domain explicitly. This calculation happens when preparing the map; it is not a scroll animation.

Before use, points are sorted, duplicate source coordinates are resolved, nonfinite coordinates are discarded, and preview coordinates are kept nondecreasing. These rules prevent a forward source movement from producing a backward preview movement. Actual clip movement is also clamped to the rendered document's scrollable bounds.

## 4. Interpolate linearly

For the current source viewport origin, find its two surrounding map points. Let their source origins be `s0` and `s1`, and their preview origins be `p0` and `p1`:

```text
fraction = (sourceOrigin - s0) / (s1 - s0)
previewOrigin = p0 + fraction * (p1 - p0)
```

For example, if the source is halfway between two map points, the preview is halfway between their corresponding points. The lookup uses a binary search through the ordered points. Outside the map's range, the nearest segment is extrapolated and the final movement is clamped.

Within one interval, preview travel per point of source travel is constant. A table does not accelerate and decelerate from row to row. The ratio can change at the next heading or image landmark, because the layouts between that pair can have a different relative height.

Constant gain is not constant speed over time: AppKit still controls the user's input acceleration and momentum. There is no additional easing filter or image-specific speed limit. If a tall image occupies a short source interval, that interval can have a high gain.

## 5. Move one native viewport

Normal editor wheel input belongs to the native source scroll view. Each bounds change supplies the current source viewport position to the preview. The map produces the corresponding preview origin immediately.

The rendered Ultralight surface sits inside an external native clip view. The clip moves with fractional-point coordinates and no animation. Ultralight receives a local scroll origin only to paint the appropriate pixels from the mounted window; the native clip and the committed map remain the owners of the document position.

Vertical wheel input over the preview is forwarded to the source scroll view. Horizontal gestures are routed to Ultralight so wide code and math remain readable; the selected axis stays fixed through gesture momentum. When the entire source fits in its pane but rendered content does not, vertical input can move the preview independently through the remaining content. Beginning and end navigation handle the same unequal-domain case.

The source editor records the union of syntax ranges actually applied for the current revision. Receiving spans during a gesture does not count as applying them. When both rendered content and applied syntax cover the viewport and its margin, movement returns before any parser request. Standalone item and table inspectors explicitly use independent native scrolling; they do not fabricate source measurements or use proportional block mapping.

## 6. Hold the map during a gesture

Native live-scroll notifications define the gesture's lifetime. At its beginning, the preview holds the committed map. Bounds changes reuse it. Ordinary covered gesture updates do not rebuild the map.

Rendering may continue in the background, but it cannot publish additions while the displayed document covers the source viewport. Source highlighting that would alter typography also waits until the gesture ends. Deferred highlighting carries a document revision, so an edit cannot apply old spans to new text.

At gesture end, deferred highlighting is applied, the held-map flag is cleared, and deferred presentation work may proceed. With unchanged content and layout, this leaves the existing pixels and position unchanged. There is no separate settling render or animation. Edits and resizing explicitly end a gesture because they change layout.

If scrolling approaches the edge of the mounted window, the preview takes the next bounded slice from the retained cache and reconciles it by stable block ID. If preparation has not reached the destination, foreground work prepares and publishes that missing destination during the gesture. Both paths are destination work, not a rebuild on every movement.

## 7. Separate rendering progress from scrolling

Initial foreground work prepares the visible source region with overscan. Background work then proceeds from top to bottom, skipping cached regions. Tables and code fences remain complete semantic blocks even if they exceed a batch's normal line range. A single visible semantic block may therefore cost time proportional to that block, but never to unrelated document content.

Unprepared intervals occupy estimated space at their actual document positions. Navigation that outruns preparation prioritizes the destination, and background work subsequently fills the remaining gaps. The decision depends on rendering coverage, not a classification of documents as ordinary or exceptionally large.

When the displayed content cannot cover the entire source viewport, a loading state hides misleading content until the destination is prepared. The first prepared viewport can appear before the whole document completes. A pending foreground request retains priority, so background progress cannot supersede it repeatedly.

Publication has two paths:

- **Reconcile on the active surface.** The revision, width, font, asset directory and document extent must agree. Keyed sections that remain in the mounted window keep their DOM nodes; new and invalidated sections are replaced. The result publishes only after destination coverage, geometry and paint agree.
- **Prepare a replacement on the spare surface.** Edits, reflows and changes that cannot preserve a coherent active presentation use the second Ultralight surface. The current surface stays visible until the replacement is complete.

The HTML module completes DOM reconciliation, layout, geometry extraction and CPU-surface painting synchronously on its serial executor. Requests carry their own identity and captured inputs; an older result cannot publish over a newer request. Before commit, the destination is recomputed and must lie inside the painted region. Remote resources can trigger later repaint pumps, while their layout changes enter through the same measured presentation boundary.

HTML fragments cross one narrow module API. That module owns the document shell, CSS, local asset resolution, DOM reconciliation, layout, pixels, input, links and selection. Local asset URLs receive their final data URL before insertion. No page JavaScript is enabled or required.

The HTML cache retains prepared content for the open document. Edits invalidate affected cached regions; context-changing edits conservatively invalidate more. This preparation and publication machinery supports progressive rendering and incremental editing. It is not part of the interpolation formula.

Prepared cache coverage and displayed coverage are separate facts. Reaching a cached but undisplayed destination requests publication without reparsing. A request that does not cover the current destination cannot spend time fencing or publishing that destination. Background progress still waits during a covered gesture.

At startup, syntax preparation starts on its worker while the native window is constructed. Comrak parses the complete document once; HTML preparation and source styling give the first viewport priority. The HTML engine receives only the bounded initial window, while the retained cache fills in the background. Ultralight process initialization is distinct from viewport rendering time and is shared by preview surfaces.

Opening a document presents its window only after this first viewport is ready. Both panes therefore appear together; the window never exposes a source-only frame or an initial loading label. This waits for viewport publication, not complete-document rendering. It does not eliminate browser initialization latency. Once the window has appeared, subsequent show requests remain immediate. Closure cancels a pending opening.

## What we keep from MacDown

This comparison concerns original MacDown 0.7.3, pinned to commit `0a9e065b98544e8477f6ee1285fcccb5bfbc8e7b`.

MacDown retains a complete native source layout and rendered preview. Its scrolling references are headings and images, measured in both panes, with linear interpolation. Native gesture start refreshes and caches the reference arrays; gesture end clears the live-scroll flag. Preview-load completion can refresh and synchronize even during live scrolling. [MacDown gesture handling](https://github.com/MacDownApp/macdown/blob/0a9e065b98544e8477f6ee1285fcccb5bfbc8e7b/MacDown/Code/Document/MPDocument.m#L1154-L1182), [load completion](https://github.com/MacDownApp/macdown/blob/0a9e065b98544e8477f6ee1285fcccb5bfbc8e7b/MacDown/Code/Document/MPDocument.m#L229-L249).

Its exact geometry differs: source references use glyph-rectangle midpoints, pairing uses array order, and the alignment adjustment tapers back to zero near the bottom. Our source positions use line tops, pairing uses parser identities, and our reference progresses to the bottom with explicit endpoints. Our map converts origins before interpolation. [MacDown extraction and interpolation](https://github.com/MacDownApp/macdown/blob/0a9e065b98544e8477f6ee1285fcccb5bfbc8e7b/MacDown/Code/Document/MPDocument.m#L1717-L1853).

The useful simplification is stable documents plus sparse measured references. Exact formula transplantation would change boundary behavior. Its legacy WebView presentation also does not establish that modern WKWebView can safely lose our readiness checks.

# Implementation review and simplification

The implementation follows the three operations above. The source editor owns one complete native document, applied syntax coverage and a geometry revision. The controller prepares genuinely missing ranges and retains all prepared HTML. The preview owns immutable desired requests and one immutable committed presentation containing content identity, measured preview geometry, the measured source map and its source geometry revision.

## Correctness and contract defects addressed

Applied syntax coverage now belongs to the source editor, which knows when spans were actually applied. Foreground and background preparation extend the same revision-specific coverage. A covered traversal cannot trigger parsing or restyling merely because it leaves the last foreground request.

Interior source measurements are optional. A missing native line rectangle rejects a new synchronized map. It cannot become a fabricated document-end coordinate. Outside a gesture, movement also requires the committed map to match the current source geometry revision and viewport height. A height-only resize recomputes the viewport map without reparsing or changing HTML. An unavailable changed measurement holds position and shows loading. Restoring valid measurements resumes synchronization. EOF is a separate, explicit document boundary.

During editing, the previous complete presentation remains visible while its replacement prepares, including after a preparation failure. Its old map cannot drive movement for the new source revision. This retained presentation is distinct from claiming that an unprepared scroll destination is ready.

## Simplifications implemented

- Removed source-window origins, rebasing, global/local selection conversion, custom whole-document selection and source reloads during search navigation. TextKit owns the native selection. Actual text-storage character transactions update the document model, including provisional input-method text. Native layout finishes after the transaction; until then its geometry is explicitly unavailable to preview mapping.
- Removed proportional block-position mapping. Editor synchronization and independently scrollable inspectors are explicit modes with distinct input owners.
- Replaced duplicate destination calculations with one target-origin calculation, used for pending publication and ordinary movement.
- Replaced numerical inversion of the boundary rule with its direct piecewise-linear inverse.
- Replaced parallel displayed, pending, ready and positioned state fields with desired/preparing requests and a committed presentation. A surface still records which request its actual DOM contains; that can advance before commit during a permitted addition below the viewport.
- Removed partial-document map endpoint flags. Maps use global document boundaries.
- Removed duplicate fragment anchor and container ranges left by sliced rendering. Each fragment has one complete semantic source range. Stable block IDs also identify retained horizontal reading state.
- Unified table and other item inspection around the retained preview. Inspectors reuse the prepared fragment, including resolved references; they do not reparse partial source or maintain a second HTML worker or bundled renderer.
- Removed cache eviction and its configurable byte limit. Prepared content persists until edits invalidate it or the document closes. Byte accounting is a debug diagnostic only.
- Removed unused source-navigation parameters and an obsolete structural-edit flag.

These removals are intentional API and wire-format changes within this application. There are no shims for the former fields or algorithms. Parser sources and their bundled resources use the same current format.

## Optimization hypotheses and measurements

Rendering-speed optimization remains deferred. Full TextKit layout and retained DOM have document-dependent memory costs. Source measurements ensure native layout before reading a line. Neither consideration justifies restoring estimates, moving source windows or eviction. Further optimization should measure actual workloads while preserving these invariants.

## Verification and remaining uncertainty

Acceptance checks exercise full prepared forward/reverse traversal with independent parser, styling, geometry and DOM counters; missing interior measurements; independently scrolling all 800 inspector rows; height-only resizing with unchanged source geometry and no HTML updates; and the direct boundary inverse against an independent numerical solution. Existing checks remain for startup continuity, all 149 demo headings measured through AppKit screen rectangles and DOM rectangles, table momentum, image traversal, native gesture phases, stalled rendering, edits, resizing, source endpoints and asynchronous presentation failures/recovery.

The release audit inspects the packaged binary, linked frameworks and resource files. Native acceptance tests and their controls are debug-only.

Final verification on 2026-10-08 passed the native suite at the default size and at 760 × 650. Each run checked all 149 headings and 600 fast-scroll coverage observations across prose, tables and images. Both runs also passed the height-only resize, retained-document traversal, missing-measurement and independent-table checks. Core tests passed in debug (19 tests) and release (17 tests); parser tests, JavaScript syntax checking and whitespace checks passed. Both `dist/AstraMarkdown.app` and `dist/debug/AstraMarkdown.app` were rebuilt from the final source; the packaged release passed its development-infrastructure audit. Logs are retained in [the verification directory](../research/2026-10-08/scroll-model-cleanup/).

Source-paint checks additionally capture actual pixels immediately after a top-to-bottom jump and during forward/reverse traversal of the final long paragraphs. They reject blank or mostly missing text and require the native text frame, canvas height, layout bounds and geometry revision to stay unchanged. Indexed source positions are checked against independent native glyph measurements. These checks cover source painting, which the earlier map and revision counters did not. Native layout is deferred while a character transaction is open, including layout triggered indirectly by the document window's edited indicator.

These tests establish geometry, ownership and publication behavior. They do not prove that every physical display frame is free of compositor artifacts. Visual acceptance on the user's display remains relevant; no rendering-speed claim is made.

## Code guide

- [Native source layout and highlighting](../Sources/AstraMarkdown/SourceEditor.swift)
- [Foreground/background preparation and coverage](../Sources/AstraMarkdown/EditorWindowController.swift)
- [Preview mapping, gesture hold and publication](../Sources/AstraMarkdown/FragmentRenderer.swift)
- [Linear interpolation and viewport boundary conversion](../Sources/MarkdownCore/ScrollLandmarks.swift)
- [Rendered landmark measurement and resource readiness](../App/Resources/Preview.js)
- [Independent native integration checks](../Sources/AstraMarkdown/IntegrationCheck.swift)
