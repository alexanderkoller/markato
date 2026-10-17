# Scrolling, jumping, and resizing

This document is the behavioral contract for source and preview navigation.
The implementation may change, but these rules must remain true.

## One operation owns the viewport

At any moment, one operation determines the preview position:

- ordinary source movement through the source-to-preview map;
- an independent preview scroll;
- an active source scroll gesture;
- an active or just-completed resize session;
- compensation for a delayed layout change; or
- an explicit jump.

Two operations must never correct the viewport at the same time. In
particular, resize anchoring suspends ordinary reading alignment, and delayed
layout compensation must not restore a position captured before a scroll
gesture. A new explicit navigation action replaces the current owner. Passive
geometry publication preserves the current owner's anchor; if a resource
finishes during resize, for example, the resize session incorporates the new
geometry rather than applying a second compensation afterward.

The ownership transitions are:

| Event | Result |
| --- | --- |
| Source wheel, scrollbar, keyboard navigation, or explicit reveal | Release preview detachment and passive anchors; source synchronization owns the destination |
| Preview wheel | Preview becomes independently positioned until the source next moves or changes revision |
| Source gesture begins | Freeze publication that could override the gesture; keep mapping from retained source refinements current |
| Source gesture ends | Publish deferred geometry at the final source destination, then return to source synchronization |
| Resize begins | Capture one shared top-anchor session; suspend ordinary mapping |
| Resize mouse-up | End dragging but retain the same resize owner and anchors |
| First later source movement or a document revision | Release resize ownership and resume ordinary mapping |
| Passive resource or layout completion | Preserve whichever owner is active |

Event handlers may request work, but only this ownership transition may change
which rule positions the viewport. AppKit bounds notifications and completed
background tasks are observations, not implicit user intent.

## Preserve visible content, not a raw scroll offset

A document-relative pixel offset is not a stable reading position. Text can
rewrap and blocks above the viewport can change height.

When geometry may change, preserve:

1. a stable content identity, normally a retained block;
2. a position within or relative to that block; and
3. its exact position in the viewport.

At the document top, preserve the top boundary explicitly. If the viewport top
falls in inter-block whitespace, anchor the first visible block below it, not a
fully offscreen preceding block.

Geometry, pixels, scroll extent, mapping, and the compensated origin form one
transaction. The user must never see new pixels with old geometry or an
updated scrollbar with an uncompensated viewport.

## Architectural boundaries

The design depends on five components having narrow ownership:

| Component | Owns | Must not do |
| --- | --- | --- |
| `SourceEditor` and `LayoutIndex` | TextKit geometry, the source viewport, and source offset-to-Y lookup | Derive preview positions or trust estimated geometry for a jump |
| `PreparedDocument` | Stable blocks, prepared HTML, source layout, preview strides, and subtree sums | Perform browser layout or paint a viewport |
| `HTMLRendererExecutor` | Every Ultralight object, DOM layout, element measurement, and bitmap capture | Expose an engine or DOM handle to the main thread |
| `PreviewPane` and `PreviewSurface` | Viewport ownership, mapping, the committed presentation, native scrolling, and atomic publication | Accept partially validated geometry or let AppKit define the logical origin |
| `EditorWindowController` | Revision scheduling, priority and complete preparation, and creation of a shared resize session | Independently correct either pane's viewport |

Ultralight has one dedicated renderer thread. AppKit and the navigation state
remain on the main actor. The boundary passes immutable requests, geometry,
measurements, flow displacements, and bitmaps. Thread confinement is part of
correctness, not only a performance choice.

`PreviewPane` represents viewport ownership with the shared resize session,
the source-gesture flag, detached-preview state, and delayed-layout anchor.
These are one logical state machine even though they occupy several stored
properties. New behavior must not add another independent offset correction
with competing precedence.

### Identity and stale-result rejection

Asynchronous work is accepted only when all identities relevant to that work
still match:

- the document revision identifies source content;
- a stable block ID identifies an unchanged semantic block across edits;
- the block content version identifies the exact HTML submitted to Ultralight;
- the preview layout ID identifies width, font size, and stylesheet generation;
- the render token orders presentation requests; and
- the source geometry revision and viewport height identify the mapping.

A measurement is reusable only for the same block content and preview layout.
A source-to-preview map is usable only for the source geometry revision and
viewport height from which it was built. A frame is publishable only for the
current render token, document revision, and layout ID. Failing any check
rejects the result and leaves the last coherent presentation visible.

### Coordinate systems

The implementation must keep these coordinates distinct:

- a source character offset;
- source document Y from `LayoutIndex` and TextKit;
- global preview document Y;
- `windowTop`, the global Y represented by the mounted Ultralight window;
- Ultralight-local Y inside that window;
- the native logical preview origin; and
- Ultralight's applied scroll position plus the bitmap's fractional native
  residual.

For a mounted preview block, its global top is:

```text
globalBlockY = windowTop + block.y
```

Its visible position is:

```text
viewportY = globalBlockY - logicalOrigin
```

The Ultralight scroll request is local to the mounted window:

```text
localOrigin = logicalOrigin - windowTop
```

Ultralight may quantize the applied local scroll. That applied value positions
the bitmap but must never replace `logicalOrigin`. `PreviewSurface` preserves
the fractional difference by mounting the bitmap at a compensating native
offset. Feeding the quantized value back into document geometry causes the
small cumulative shifts previously seen at document end.

### Anchor model

All geometry-changing operations use the same abstraction: identify a point in
content and preserve its viewport Y. If the point's new global coordinate is
`contentY'` and its saved viewport coordinate is `viewportY`, resolve the new
origin as:

```text
origin' = contentY' - viewportY
```

The source identifies the point by character offset. The preview identifies it
by stable block ID and, when needed, a local position inside the block. The
document top is an explicit boundary anchor. If the viewport top lies in
inter-block whitespace, the preview uses the first visible block below it.

This anchor is semantic; an absolute document offset is only valid when the
geometry itself is unchanged. Resize and delayed-resource settlement differ in
when they capture and release an anchor, not in how they resolve one.

## Retained geometry and complexity

Parsing and full preview geometry construction happen in the background. The
HTML engine lays out bounded measurement slices and the application retains
their numeric block strides; it never creates a document-sized browser DOM.
Scrolling and completed-document navigation use retained lookup structures.
An isolated height change updates the affected retained-tree paths; it does not
scan or reconstruct all following positions.

Source geometry lives in `LayoutIndex`, a balanced sequence tree whose nodes
sum source length and vertical advance. It contains exact TextKit lines where
measured and estimates elsewhere. Offset-to-Y and Y-to-offset queries are
logarithmic. Replacing a measured interval retains the unchanged prefix and
suffix instead of rebasing every following line.

Preview geometry lives in the block tree in `PreparedDocument`. Each node has
a stable block ID, estimated or measured stride, and a subtree preview-height
sum. Source-coordinate shifts after a local edit are lazy at subtree roots.
Updating `k` block measurements touches those blocks and their ancestor paths,
not every following block. A global preview prefix is obtained from subtree
sums.

Ultralight remains authoritative for actual browser layout. When asynchronous
content changes, it reports dirty wrapper IDs. The renderer queries each dirty
wrapper and its next flow boundary, then reports the suffix displacement as a
compact delta. Any maintenance of the renderer-local geometry array stays on
the renderer thread; the main thread receives measurements and displacements,
not an instruction to requery the document.

The main thread may perform bounded TextKit measurement, retained-tree lookup,
validation, and atomic publication. Source measurement completion may use
small main-run-loop batches because TextKit is main-thread-bound. No gesture,
jump, resize callback, or height-change commit may perform work proportional
to document size. Full preparation may be document-sized on its background
worker. Ultralight work, including background measurement, remains bounded.

## Atomic publication

Every new presentation follows one commit protocol:

1. Snapshot the document revision, preview layout ID, source coverage, width,
   and render token.
2. Lay out and measure on the Ultralight thread.
3. Reject stale output on the main actor.
4. Validate and apply block measurements to the retained tree.
5. From that same geometry, compute global extent, mapping, and the origin
   required by the current viewport owner.
6. Capture Ultralight at the corresponding local origin. If a resource changed
   geometry between layout and capture, recompute and capture again before
   publishing.
7. In one animation-disabled transaction, publish the bitmap, committed
   geometry, mapping, scroll extent, native surface size, and logical origin.

There is exactly one committed presentation. A desired request, an in-flight
request, or a pending resource frame is not visible state. Failure or
supersession discards that work and retains the committed presentation.

## Ordinary synchronized scrolling

Source movement normally owns synchronized navigation. The committed mapping
converts the source reading position to the corresponding preview reading
position. Near the document boundaries, that reading position transitions
between the viewport top, the upper golden-ratio division about 38.2 percent
from the top, and the viewport bottom so both panes can reach their true ends.
In the document interior, the panes are aligned at that golden-ratio position.

This reading-alignment rule applies only to ordinary source movement. It does
not apply while resize anchoring or delayed-height compensation owns the
viewport.

During a source gesture, the latest source position is authoritative. At
gesture end, deferred work is positioned against that final location; no
gesture-start position may be restored. A preview scroll may move independently
until the source moves again or the document revision changes.

Activating an outline heading places that heading at this same reading
position in both panes. It sits at the upper golden-ratio division in the
document interior and follows the same continuous top- and bottom-alignment
transitions near the document boundaries. The outline's active row is derived
from that shared position, so the clicked heading remains active after
viewport synchronization.

### Mapping algorithm

The map is built from stable block landmarks. Each point pairs a source
passage Y with the corresponding global preview Y. Exact document boundaries
are added as endpoints. Before interpolation, each passage point is converted
to the viewport origin that produces top alignment near the beginning,
golden-ratio reading alignment through the interior, and bottom alignment near
the end. Alignment
is therefore encoded once in the map rather than subtracted after lookup.

The points are ordered by source Y and forced to be monotone in preview Y.
Lookup is piecewise linear with binary search. Consequently, forward source
movement cannot move the preview backward, and a scroll event costs
`O(log L)` for `L` landmarks plus a native clip move and renderer paint request.

The map is constructed from one source geometry revision. If source geometry
changes while landmarks are being read, construction is abandoned. A committed
map carries that revision and the viewport height; `PreviewPane` refreshes it
before ordinary placement when either no longer matches.

### Painting algorithm

Logical scrolling first moves the native clip and records the requested local
Ultralight origin. Renderer requests use a latest-value mailbox: destinations
that have not started painting may be replaced by a newer destination. Once a
bounded surface scroll has started, it is allowed to finish so continuous
input cannot starve visible publication. A quiet-period settlement then paints
the exact final destination.

Resource ticks share the renderer queue and must receive service during a
continuous scroll. Ordinary scroll painting may shift retained pixels and
paint the exposed strip; it must not relayout the document or rebuild the DOM.

## Jumps

A jump is explicit navigation, not an unusually large scroll delta.

- Use retained estimates to reach the destination immediately, then replace a
  bounded region around it with exact TextKit geometry. Geometry above the
  viewport need not be exact: later corrections shift the target and its
  logical origin together.
- Start and end commands target exact document boundaries. They are not
  percentages and are not inferred from an estimated scrollbar maximum.
- A jump releases any resize or delayed-layout anchor that would otherwise
  override the requested destination.
- A jump explicitly requests a bounded destination window. It must not wait
  for background geometry, mount a document-sized DOM, or expose a loading
  placeholder. A previously measured destination is retained lookup plus
  bounded layout and paint.

The source refines a bounded logical-line region around the destination before
moving its clip. Background TextKit measurement may later correct geometry
above it, but the visible source and preview anchors remain fixed. A new
explicit navigation supersedes the current destination.

Cmd-Home and Cmd-End additionally tell the preview that the navigation target
is the exact start or end boundary. This is a navigation decision only. After
arrival, later resource growth still uses ordinary visible-content anchoring
rather than a permanent "stick to bottom" mode.

## Delayed height changes

Images, raw HTML, Mermaid, KaTeX, or other asynchronous content can change a
block's vertical stride. The renderer identifies affected wrappers; only those
wrappers are remeasured. Accepted measurements update the retained tree and
its ancestor sums.

Before committing the change, capture the visible-content anchor. Apply the
accumulated height delta above that anchor to the preview origin:

- growth or shrinkage above the viewport changes the origin by the same delta;
- a change below the viewport changes the origin by zero; and
- the document top remains exactly zero.

Thus the preview grows or shrinks invisibly around the viewport. The same rule
applies after Cmd-End; the document end is not a special anchoring mode. The
scrollbar extent may change while the visible passage remains still.

If a height change races a gesture, retain the new geometry but defer its
visible publication until the gesture ends, then evaluate compensation at the
gesture's final destination. Passive AppKit clip corrections are not user
navigation and must not release the anchor.

### Height-change algorithm

For each dirty wrapper, the renderer returns its new stride and the displacement
of the following flow boundary. Let the old logical origin be `o`. The origin
for the new geometry is:

```text
o' = o + changeInWindowTop + sum(displacement before the top-visible block)
```

The first block whose old box intersects the viewport top determines which
flow displacements count. If the top lies in whitespace, the first block below
it is the anchor. No downstream Y positions are queried on the main thread.

The retained block tree accepts a measurement only when revision, block ID,
content version, and layout ID match. The new document extent and compensated
origin are calculated before capture. If the logical origin changes while the
resource settlement is being captured, the settlement is recomputed against
the newer origin. A generation number prevents an older settlement from
publishing after a newer one.

While source momentum or resize owns the viewport, at most the current pending
resource geometry is retained for later publication. At release it is resolved
under the active operation's final anchor; it is never committed first and
then corrected by a second visible move. If all changed blocks are outside the
viewport, geometry and scroll extent may commit while retaining the existing
bitmap byte-for-byte.

## Resizing

Resize is one application of the shared anchor model. At gesture start, the
controller creates one `ViewportResizeSession` containing the source offset and
preview block at the viewport top, together with their exact viewport
displacements. Both panes retain that same session.

At every intermediate width, TextKit and Ultralight reflow independently and
each pane resolves its saved anchor. Ordinary reading-aligned synchronization is
suspended. The source clip rejects incidental AppKit origin corrections while
protected; the preview uses the normal asynchronous publication path. A
completed coherent width may be displayed while a newer width remains queued,
which gives real-time reflow without publishing mixed geometry and pixels.

Taking resize ownership also cancels publication of scroll work requested for
the preceding viewport. A committed resize capture advances Ultralight through
at least two renderer cycles: the first cycle may report the forced
invalidation while only updating scroll metrics, and the second makes those
metrics visible in the software surface. Geometry and pixels are not published
from different cycles.

Mouse-up finalizes the width but does not release the anchors. Final TextKit
measurement, final bounded Ultralight layout, queued callbacks, and completed
background-geometry publication all resolve the same session. The session ends
only on genuine source navigation or a document revision. Ordinary center
alignment resumes on that next navigation, not on mouse-up.

Within one revision both semantic anchors must remain resolvable; otherwise the
result is stale and is rejected. The document top is an explicit boundary. The
document end needs no special resize behavior.

## Scrollbars

A scrollbar represents the best committed document extent. Before complete
layout it may use retained estimates; afterward it uses exact retained
geometry. Extent, thumb, pixels, and compensated origin are published
atomically.

The thumb may move when offscreen content changes height even though the
visible passage does not. Do not preserve a percentage, snap to a newly changed
maximum, or let scrollbar rounding move the content anchor.

## Priority render and complete geometry

For a new revision or width, prioritized rendering produces the visible area
and bounded runway first. Background work continues until every block's HTML
and numeric geometry are retained. Foreground and steady-state browser DOMs
remain bounded.

Publishing completed background geometry is not navigation. Whichever
operation currently owns the viewport must survive the final extent update,
including a completed resize session and a delayed-height anchor.

The priority window is selected from the retained block tree by source range
and accumulated preview stride. Its global `windowTop` and total document
height come from subtree sums, so omitted blocks do not become placeholder DOM
elements. Replenishing a priority window changes the mounted range but not the
global preview coordinate system.

Background preparation advances through missing HTML and source measurement
without evicting prepared blocks. Small, low-priority Ultralight measurement
windows then fill preview strides. Each slice is short enough that visible
scrolling or destination rendering does not wait behind a long non-preemptible
layout. Exact geometry stays retained until a new document revision or preview
layout ID invalidates it; distant movement still replaces the bounded visible
window.

If a new edit or width supersedes preparation, obsolete work may be coalesced
or rejected by identity. The system must not silently abandon completion and
remain permanently windowed.

## Required verification

Automated checks must exercise the behavior, not merely helper calculations:

- sustained synchronized scrolling at interactive frame rate;
- deep jumps whose source destination initially lies beyond measured geometry;
- Cmd-End before and during a delayed image load;
- delayed growth and shrinkage above and below the viewport;
- height changes during momentum, settled at the final gesture destination;
- real-time resize through many intermediate widths, with a near-top landmark
  fixed to the exact device-pixel row;
- no movement on mouse-up, final-width layout, or completed-geometry publication;
- the next genuine source movement releasing the resize anchor and restoring
  golden-ratio reading alignment;
- top, middle, bottom, fractional-origin, stale-result, and failure cases;
- rejection of wrong revision, render token, content version, layout ID, and
  source geometry revision;
- latest-value scroll coalescing and fair resource progress under continuous
  input;
- no main-thread full-document pass in gesture, jump, resize, or resource
  settlement diagnostics; and
- no loading panel during a bounded destination replacement after background
  completion.

The regression gate is:

```sh
bash scripts/check-preview.sh
```

## Code guide

- [Native source layout and highlighting](../Sources/Markato/SourceEditor.swift)
- [Foreground/background preparation](../Sources/Markato/EditorWindowController.swift)
- [Preview mapping and publication](../Sources/Markato/FragmentRenderer.swift)
- [Ultralight rendering boundary](../Sources/HTMLPreview/HTMLPreviewView.swift)
- [Retained prepared document](../Sources/MarkdownCore/PreparedDocument.swift)
- [Scroll interpolation](../Sources/MarkdownCore/ScrollLandmarks.swift)
- [Integration checks](../Sources/Markato/IntegrationCheck.swift)
