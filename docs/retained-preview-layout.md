# Retained preview layout

Status: implemented architecture

## The model

The preview has two complementary stages for each document revision.

1. **Priority render.** Render the source viewport plus twelve preview
   viewports of runway on each side. This is the first frame and the fallback
   after an edit. It must become visible without waiting for the rest of the
   document.
2. **Complete geometry.** Continue preparing the document in the background,
   then give Ultralight small consecutive measurement windows. Store their
   numeric block strides in `PreparedDocument` and discard each measurement
   DOM when the next slice replaces it.

The retained application model is complete, but the browser presentation is
always bounded. Scrolling within its runway is lookup plus paint. Crossing the
runway or jumping to a distant section lays out and atomically publishes a new
bounded window. No placeholder elements or document-sized DOM are used.

## Block geometry

Every top-level Markdown block has an application-owned wrapper. The wrapper's
border-box height is the block's vertical stride. Spacing belongs inside the
wrapper, so measuring a block never depends on whether the following block is
present.

`PreparedDocument` stores, for each block:

- a stable block ID;
- a numeric stride;
- whether the stride is estimated or measured;
- the layout identity for a measurement; and
- the content version for a measurement.

Subtree sums make a block prefix, suffix displacement, and document-height
change logarithmic. A measurement is accepted only if its document revision,
block ID, content version, and layout identity still match.

Before complete measurement, estimates make every destination navigable.
Afterward, the accumulated Ultralight block measurements are authoritative for
the current revision and width. Estimates remain useful while preparing the
next layout identity after an edit or width change.

## Publishing geometry

A visible frame and the geometry used to position it are one transaction.
Ultralight returns the bitmap, wrapper geometry, and changed measurements from
the same render. The controller then:

1. rejects stale results;
2. accepts the new measurements;
3. computes their vertical delta above the viewport;
4. builds the corresponding source-to-preview mapping;
5. adds that delta to the document-relative scroll origin; and
6. publishes pixels, geometry, scroll extent, mapping, and origin together.

There is no intermediate state in which new pixels use old heights or a new
scrollbar uses the old origin.

## Images and other delayed layout

Local raster images reserve their intrinsic aspect ratio before decoding. The
dimensions come from image metadata, so ordinary local images normally do not
change block height when their pixels arrive. This explains why lazy image
loading often appeared harmless before explicit height handling existed.

Intrinsic dimensions are not always available. Raw HTML may contain an image
without dimensions, a `<details>` element may open or close, and future
asynchronous Mermaid or KaTeX rendering may replace content. Ultralight's
delegated resource and element events identify the affected wrapper. After
layout, only those wrappers are remeasured. An event marks a block dirty; it is
not itself evidence that the height changed.

If the stride changes, the retained tree updates that block and its ancestors.
Unchanged blocks are not remeasured. A paint-only resource result does not
touch the tree or scroll mapping.

Ultralight also reports the changed block's next flow boundary. This exact
boundary displacement is the viewport-compensation delta; downstream Y
coordinates are not rediscovered individually. The retained suffix is shifted
by that delta.

## Stable viewport

For a height change, the preview compares the old and new document coordinate
of the block at the viewport top. Their difference is the accumulated height
change above the viewport. It adds exactly that delta to the scroll origin.
The block therefore keeps the same viewport coordinate while content above it
grows or shrinks. A change below the viewport contributes zero. The document
top remains at zero.

The same rule applies at every other position, including a viewport reached by
Cmd-End. The bottom is not a separate mode. If trailing geometry changes by a
fractional pixel in addition to the geometry above the viewport, the new
scrollbar maximum may end up fractionally below the stable viewport. Snapping
to that maximum would move visible content and is therefore incorrect.

Ultralight quantizes an applied DOM scroll position more coarsely than retained
layout coordinates. Every capture and live scroll paint therefore reports
Ultralight's applied position, while the native surface retains the requested
logical position separately. Their fractional residual is represented by where
the bitmap is mounted inside the native clip; it is never rounded into viewport
motion. Height compensation is calculated from the logical position, never the
quantized paint position.

During a gesture, the changed geometry is retained rather than an old absolute
offset. When the gesture settles, the delta is evaluated at the latest scroll
destination and added there, so resource completion cannot undo momentum or
apply a below-viewport change after the gesture crossed above it.

## Scrolling and gesture races

After complete geometry, synchronized scrolling inside the mounted runway is a
position lookup against the committed mapping. Crossing the runway schedules a
bounded replacement; it never parses or lays out the whole document.

Scroll paints use a latest-value mailbox. The renderer keeps at most one
pending destination and never publishes a bitmap for a superseded destination.
Live input uses Ultralight's surface-scroll path, which shifts existing pixels
and paints the exposed strip. Once input is quiet, one exact viewport repaint
settles the final destination. Continuous scrolling therefore does not force a
full repaint per source event. Resource deadlines are serviced fairly alongside
scroll paints, so a continuous input stream cannot prevent a delayed image from
loading.

During a source scroll gesture, the source position remains authoritative.
Resource-driven preview frames are held until the gesture ends. Source text
layout may still refine during momentum; in that case the mapping is refreshed
from retained geometry so the preview continues to follow the live source
position. At gesture end, any deferred preview frame is committed directly at
the final source position. A gesture-start anchor is never restored over the
gesture's destination.

An anchored resource commit is released by explicit scroll or navigation
intent, not by comparing source scroll offsets. AppKit may make a small clip
correction to keep a focused insertion point visible after layout settles; that
correction is not a new navigation request and must not move the preview. A
real scroll gesture, Cmd-End navigation, preview scroll, or replacement of the
scroll source releases the anchor before applying the shared mapping.

Window replacement begins while runway remains and retains the old bitmap until
the replacement is ready, so a long scroll or jump does not expose a “Loading
preview” panel. Visible work has priority over background measurement.

## Scrollbars

Before complete layout, the scrollbar uses the retained estimated total.
Height corrections may change the thumb, but anchoring prevents visible
content from moving.

When complete geometry is available, its accumulated exact block strides
become the scroll extent. Later isolated height changes update that extent in
the same atomic transaction as their pixels and anchored origin.

If every changed block is outside the viewport, the visible bitmap is already
the correct picture of the anchored content. The commit therefore updates the
retained geometry, DOM state, hit-testing coordinates, and scrollbar extent
without replacing those pixels. The existing bitmap remains byte-for-byte
stable until the next scroll or a change that intersects the viewport. This
also avoids glyph-antialiasing changes caused solely by repainting text at a
different absolute document coordinate.

## Resizing

A width change creates a new layout identity and reflows both panes in real
time. One resize session captures the source and preview content at their
viewport tops. Every intermediate layout resolves those same anchors, so the
top visible content remains at the same painted coordinate while wrapping and
document origins change.

Ordinary reading-aligned source-to-preview mapping is suspended for the entire
session. Mouse-up does not end the anchoring rule: the same session survives
final TextKit measurement, final bounded Ultralight layout, and completed
background-geometry publication. It is released only by genuine
source movement or a document revision; the next source movement resumes
ordinary reading alignment. Mouse-up must therefore produce no viewport
correction.

Each published resize frame is one coherent width, geometry, mapping,
scrollbar, origin, and bitmap. No mouse event walks or lays out the document
synchronously. See [Scrolling, jumping, and resizing](scrolling-algorithm.md)
for the complete navigation contract.

## Edits

An edit keeps the last committed bitmap visible. The parser preserves stable
block identities and retained measurements outside the changed region. A
priority render publishes the new revision near the viewport; background work
then restores complete retained geometry for that revision.

An edit therefore does not trade responsiveness for the steady-state
guarantee: the user gets a local update first, and exact global coordinates
again after background completion.

## Work placement

Document-sized parsing and HTML construction belong off the main thread.
Ultralight measurement is split into small renderer-thread slices because an
individual layout transaction is not preemptible. The main thread performs
bounded validation and tree updates. Incremental height changes update only
affected paths.

The renderer may coalesce obsolete background work, but there is no fallback
architecture in which complete retained geometry is silently abandoned. A new
revision cancels the old revision's measurement sequence and starts the same
two stages again.

## Required tests

Automated tests must cover:

- a bounded first frame followed by complete retained geometry;
- a deep jump before and after completion with no loading panel or
  document-sized DOM;
- delayed image growth and shrinkage above the viewport;
- a height change from an explicitly fractional logical scroll origin, checked
  to subpixel precision before and after Ultralight paint settlement, with
  byte-identical visible pixels when the changed block is offscreen;
- Cmd-End during delayed image loading, with the viewport stable and no later
  snap to a fractionally different scrollbar maximum, including with a focused
  source insertion point and a later passive source clip correction;
- an explicit source scroll after that correction, proving the stability anchor
  is released and synchronized scrolling resumes;
- a height change during momentum, committed at the gesture's final position;
- resize at the top, middle, and bottom;
- an edit followed by priority and completed-geometry publication without
  viewport motion;
- stale revision, content-version, and layout-identity rejection; and
- exact scrollbar extent after complete layout.
