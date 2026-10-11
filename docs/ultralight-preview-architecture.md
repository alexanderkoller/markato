# Ultralight preview architecture

Status: implemented on 11 October 2026 through the stock CPU surface. The
retained tree, bounded window, native scroll map, DOM reconciliation, CSS,
assets, input, links, selection copying, and bitmap publication are integrated.
The native accessibility adapter and selection pinning across window eviction
remain release gates.

## Decision

Use Ultralight behind one `HTMLPreview` module and keep the mounted HTML bounded.
The module consumes the existing `RenderedWindow` values and stable semantic
block IDs from `PreparedDocument`. It must not construct another document tree,
split semantic blocks, or change the source/preview scrolling equations.

Ultralight should never receive the complete document DOM. The complete cache
remains in `PreparedDocument`; Ultralight receives the current viewport plus
overscan. Time is consequently proportional to the complete semantic elements
intersecting that bounded window, rather than the complete document.

Start with Ultralight's CPU surface. It provides a simple atomic frame boundary
and the measured renderer work is already within the frame budget. A Metal
driver can be considered later if integrated profiling finds bitmap transfer or
painting expensive. Do not fork WebCore or the proprietary Ultralight components
before the stock bounded implementation identifies a specific remaining cost.

The recommendation to ship is conditional on a satisfactory commercial/source
license and a native macOS accessibility bridge. Ultralight's documented ARIA
and accessibility hooks are not connected to operating-system accessibility
services. That missing integration belongs inside `HTMLPreview` and remains a
release gate.

## Evidence

The earlier complete-DOM benchmark mounted identical Markdown-derived HTML in
each renderer. Ultralight was the fastest full HTML implementation, but an 8 MiB
document still took 1,052 ms to first pixels, 86 ms to materialize a deep view,
62 ms for a visible edit, and 1.37 GB RSS. Replacing WKWebView while retaining a
complete DOM would therefore leave the document-size problem intact.

The follow-up probe mounted only existing semantic block wrappers. It used the
native Ultralight DOM API with JavaScript disabled, retained overlapping nodes
by identity, and performed layout and CPU rendering after every operation. Five
fresh processes were measured for every window/document pair. The 384-block
window was approximately 22.8 viewports high in this fixture. As in the earlier
renderer benchmark, Ultralight renderer/view construction precedes the HTML
timers; the persistent shell is intended to be initialized concurrently with
Comrak rather than placed after it on the first-view critical path.

| Source document | Blocks in document | First bounded view | Local scroll | 48-block refill | Cold deep window | Visible edit |
|---:|---:|---:|---:|---:|---:|---:|
| 64 KiB | 685 | 39.2 ms | 1.27 ms | 2.0 ms | 3.4 ms | 0.12 ms |
| 1 MiB | 10,879 | 39.2 ms | 1.28 ms | 1.9 ms | 3.8 ms | 0.11 ms |
| 8 MiB | 86,597 | 38.6 ms | 1.26 ms | 1.9 ms | 3.9 ms | 0.12 ms |

The first-view interval includes navigating to an HTML document containing the
shell, stylesheet, and initial window. The intended persistent-shell path was
also measured directly. Inserting and rendering the first 384 blocks into an
already loaded empty shell took 1.23, 1.23, and 1.24 ms for the three document
sizes (observed maximum 1.38 ms). Ultralight initialization and shell creation
can run while Comrak parses on a separate serial executor.

All overlap checks passed: a block retained across a refill remained the same
DOM node. Reading the heights of all 384 mounted blocks took about 0.04 ms.
Increasing the window from about 8 to 30 viewports changed a cold deep-window
replacement from about 1.3 to 4.5--5.5 ms. None of these values increased with
the total document size.

The accepted exception was also measured. A single visible table took 30.5 ms
at 100 rows, 36.7 ms at 1,000 rows, and 133.0 ms at 10,000 rows. This is the
intended rule: work may grow with a complete visible semantic element. Tables
and code blocks remain complete semantic blocks, preserving stable table layout
and the retained-tree contract.

The fixtures contain ordinary headings, paragraphs, emphasis, links, and code,
with no external resources. Integrated testing must still cover the application's
KaTeX output, images, wide tables, selection, input routing, resize, appearance,
and accessibility. The measurements establish the scaling property and the DOM
operations needed for the architecture; they are not a complete compatibility
test.

Raw measurements and the reproducible harness are under
`research/2026-10-11/html-renderer-benchmark/`. In particular:

The integrated release app was then measured with the preserved application
probe, three fresh processes per size and three visible one-character edits per
process. These intervals include Comrak and the native source update as well as
HTML presentation.

| Dense Markdown | Ultralight open | Ultralight edit | Previous bounded WebKit open | Previous bounded WebKit edit | MacDown 3000 open | MacDown 3000 edit |
|---:|---:|---:|---:|---:|---:|---:|
| 64 KiB | 92.1 ms | 33.9 ms | 119.4 ms | 28.3 ms | 205.8 ms | 52.7 ms |
| 1 MiB | 79.5 ms | 54.7 ms | 122.8 ms | 56.5 ms | 2,542.0 ms | 2,004.1 ms |
| 8 MiB | 359.8 ms | 205.5 ms | 370.3 ms | 562.0 ms | — | — |

The 64 KiB open distribution remains noisy (53.8--140.5 ms), so the median is
reported rather than claiming monotonic size scaling. At 8 MiB, total edit time
is now dominated by the deliberate whole-document Comrak pass; dispatch itself
was 1.4 ms median and the bounded renderer does not explain the remaining
roughly 200 ms. No saved 8 MiB MacDown 3000 result exists; its preserved 4 MiB
stress run is not directly comparable.

- `src/ultralight_window_bench.cpp`
- `run_ultralight_window.py`
- `ultralight-window-summary.json`
- `ultralight-window-scroll-summary.json`
- `ultralight-prewarmed-first-view-summary.json`
- `ultralight-visible-element-summary.json`

## Module boundary

`HTMLPreview` is the only architectural module allowed to import or link
Ultralight. Swift/C++ interoperation may require a private implementation target,
but that target is part of the module and is never imported by the application.

```text
MarkdownCore
  TextRope, Comrak results, PreparedDocument retained tree
              |
              | existing RenderedWindow / PreparedBlockChange
              v
HTMLPreview
  viewport policy, DOM reconciliation, CSS, resources, layout,
  bitmap publication, input, selection, links, accessibility
              |
              | committed global geometry and user intents
              v
AstraMarkdown controller
  source ownership, calibrated source/preview map, document commands
```

`PreparedDocument` remains the document authority. Its block ID, source range,
cached `PreviewFragment`, measured preview height, and subtree height sum are the
only retained preview records. `HTMLPreview` keeps a transient map from those
same block IDs to mounted DOM handles. It discards that map as blocks leave the
window.

The public facade should be an AppKit view with renderer-neutral value types:

```swift
@MainActor
public protocol HTMLPreviewContentSource: AnyObject {
    func window(
        covering sourceRange: NSRange,
        before: CGFloat,
        after: CGFloat
    ) -> RenderedWindow?

    func previewMeasured(
        _ heights: [String: CGFloat],
        revision: Int,
        layout: HTMLLayoutIdentity
    )

    func previewNeedsContent(_ sourceRange: NSRange)
}

@MainActor
public final class HTMLPreviewView: NSView {
    public weak var contentSource: HTMLPreviewContentSource?
    public weak var delegate: HTMLPreviewDelegate?

    public func setDocument(_ state: HTMLDocumentState)
    public func setViewport(_ target: HTMLViewportTarget)
    public func apply(_ change: HTMLDocumentChange)
    public func beginScrollGesture()
    public func endScrollGesture()
}
```

`HTMLDocumentState` contains revision, source length, layout identity, base asset
location, and stylesheet generation. `HTMLViewportTarget` contains the visible
source range, global preview origin, viewport dimensions, and whether a gesture
is active. `HTMLDocumentChange` carries the existing manifest change and cached
entries prepared by `PreparedDocument`. These types do not expose DOM, WebCore,
Ultralight, JavaScript, or renderer-thread objects.

The controller continues to own the calibrated `ScrollLandmarks` mapping. The
module returns measured block rectangles and sparse landmark offsets in global
preview coordinates. It never derives a new source-to-preview scrolling policy.

## Window and frame behavior

The module maintains one committed presentation and one desired target. A
presentation contains:

- document revision and layout identity;
- ordered mounted block IDs and fragment fingerprints;
- source coverage;
- `RenderedWindow.previewTop` and `previewHeight`;
- measured local rectangles and global sparse landmarks;
- the last complete displayed bitmap.

An exact repeated request is a no-op. Requests already covered by the mounted
window change only the local Ultralight scroll position. Multiple requests while
a refill is running coalesce to the latest destination.

For an adjacent window, the module computes the overlap by existing block ID and
fragment identity. It removes nodes outside the new interval, retains common
nodes, and prepends or appends new cached fragments through the native DOM API.
It performs one update/layout/render cycle and measures the mounted blocks once.
For a nonoverlapping jump it replaces the bounded root contents once.

The native AppKit view owns the logical whole-document coordinate space. The
Ultralight page has no document-sized spacer and no document-sized surface:

```text
local Ultralight Y = global preview Y - RenderedWindow.previewTop
logical scrollbar height = RenderedWindow.previewHeight
```

The module keeps the last committed bitmap visible while mutating and rendering
the next Ultralight frame. It publishes the new bitmap and its matching geometry
together. This gives an atomic presentation without maintaining two complete
Ultralight views. On a CPU surface, a front/back pixel buffer is enough. Resource
or layout refinements repeat the same transaction and retain a visible block and
within-block offset as the anchor.

Use the existing approximately 24-viewport window initially: twelve viewports of
runway in each direction, biased toward the movement direction only after an
integrated velocity/latency trace justifies it. The measured 23-viewport refill
was below 2.2 ms in the first matrix and a cold nonoverlapping replacement was
below 5.2 ms. These medians and observed maxima fit both 60 Hz and 120 Hz frame
budgets on the benchmark machine. Integrated p99 measurements with images and
real application scheduling must determine the final reserve.

## Editing

An edit follows the retained-tree change manifest. The module compares the
committed IDs and HTML fingerprints with the new bounded window:

1. Retain unchanged prefix and suffix DOM nodes.
2. Replace, insert, or remove only changed mounted semantic blocks.
3. Leave source-coordinate shifts in `PreparedDocument`; do not rewrite every
   suffix DOM attribute.
4. Run one layout/render transaction.
5. Return changed heights and global landmark positions.
6. Commit the frame while preserving the visible block and offset.

Offscreen edits update the retained cache and aggregate tree only. They cause no
DOM operation until their blocks enter the mounted window. Width, typography,
stylesheet, device-scale, or resource-size changes produce a new layout identity;
old heights cannot be reused under that identity.

## Responsibilities contained by `HTMLPreview`

The module owns every browser-specific concern:

- Ultralight initialization, version pinning, renderer thread, update loop, and
  shutdown;
- persistent shell, bundled CSS, KaTeX CSS and HTML compatibility;
- native DOM handles, reconciliation, selection pinning, layout and paint;
- custom asset resolution, image decode/cache, known image dimensions, font
  loading, and resource readiness;
- mouse, keyboard, cursor and horizontal overflow input;
- conversion of vertical wheel/trackpad gestures into delegate intents so the
  source remains the vertical owner;
- link activation, context menus, selected-text copy, focus and selection;
- per-block horizontal scroll state for wide tables and code blocks when a block
  is evicted and remounted;
- appearance, font, width and device-scale invalidation;
- crash/error reporting and a nonmisleading loading state for missing content;
- macOS accessibility elements, roles, labels, text ranges, actions, and frames;
- SDK libraries, resources, notices, signing and licensing compliance.

JavaScript remains disabled. Comrak and KaTeX already provide final HTML, and
Ultralight 2.0's native DOM API supplies the required mutations and events.

Selection is a window-lifetime concern. Blocks containing selection endpoints
must be pinned while selection is active, and approaching an edge requests more
cached blocks before evicting the opposite side. Context-menu and copy behavior
must operate on the committed selection, not on application HTML strings.

Ultralight is not thread-safe. Every Ultralight and DOM call currently runs on
the main actor, which is the renderer's single serial executor. This avoids a
cross-thread pixel copy in the calibrated scroll path. If profiling shows that a
large visible semantic element stalls AppKit, the module can move the same API
to a dedicated serial executor and publish complete frames back to AppKit.

## Accessibility and licensing gates

Ultralight currently documents that ARIA and platform accessibility hooks are
not connected to operating-system accessibility services. Shipping the preview
without a native accessibility tree would be a regression from WKWebView. The
module should build `NSAccessibilityElement` objects from mounted semantic
blocks and DOM rectangles, expose links and headings with suitable roles, and
request adjacent windows during accessibility traversal. This remains required
before a release that claims full VoiceOver support.

The free SDK does not permit modification of proprietary Ultralight components.
Public WebCore can be modified under its open-source licenses, while proprietary
Ultralight and UltralightCore source requires an appropriate commercial source
agreement. Review the executed agreement before distributing modified binaries.
The stock bounded implementation should be completed first; the measurements do
not presently justify maintaining an engine fork.

## Implementation status

Implemented: the isolated Swift module and C++ bridge; two prewarmed stock CPU
surfaces; bounded `RenderedWindow` mounting; stable-ID overlap retention;
measurement; local scrolling; pixel publication; the existing logical-height
and calibrated map contracts; edit patching; bundled CSS and KaTeX styles; local
images; links; mouse selection and copying; horizontal overflow; resize; and a
renderer-neutral integration path.

Remaining release work: preserve a selection whose endpoint would be evicted,
add the native accessibility adapter, test remote image failures and appearance
changes, and profile very large visible tables in the integrated app. Metal or
engine changes remain conditional on those measurements.

This structure makes Ultralight replaceable. If its license, accessibility, or
stability proves unacceptable, a different HTML engine can implement the same
module without changing the retained document, scrolling controller, or edit
pipeline.
