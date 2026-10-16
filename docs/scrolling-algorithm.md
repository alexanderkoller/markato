# How synchronized scrolling works

Markato keeps source editing, Markdown preparation, Ultralight layout, and
preview painting separate. Scrolling reads retained state; it does not parse
Markdown or replace a completed preview document.

## State ownership

The editor retains the complete source text. Its `LayoutIndex` combines exact
TextKit line measurements with estimated gaps in one source coordinate system.
Visible or navigated regions replace estimates without rebasing the rest of
the document.

`PreparedDocument` retains the ordered Markdown blocks, cached HTML, syntax,
source layout, and preview block strides. Stable block IDs let edits keep
unchanged content and geometry.

One `PreviewPane` owns the committed Ultralight presentation: revision, source
coverage, block geometry, source-to-preview map, scroll extent, and bitmap.
A pending request cannot partially overwrite it.

## Priority, then completion

For a new revision, the foreground request renders the source viewport with
twelve preview viewports of runway on each side. This prioritized frame keeps
startup and editing responsive.

Background preparation continues until every block has HTML. The complete
ordered block list is then laid out by Ultralight on its renderer thread and
published atomically. The complete DOM stays mounted. From that point, a deep
scroll is only a map lookup and viewport paint; it cannot expose “Loading
preview” or trigger another presentation.

An edit starts the same sequence again while keeping the last coherent frame
visible: prioritized new-revision frame first, complete background frame next.

## Mapping source to preview

Headings and standalone images are sparse landmarks. Each landmark pairs a
source position with Ultralight geometry. Document boundaries supply the
endpoints. The map interpolates monotonically between adjacent points, so
forward source movement cannot move the preview backward.

Near document boundaries, the reading reference transitions between the top,
middle, and bottom of the viewport so both panes reach their true endpoints.
Source geometry refinements advance a revision counter; the preview accepts a
map only when all of its positions came from one source geometry revision.

## Moving the viewport

Vertical source input evaluates the committed map and changes the preview
origin. Vertical input over the preview moves it independently until the next
source movement or source revision change. Horizontal preview gestures remain
inside Ultralight.

During a source gesture, the source position is authoritative. Resource-driven
frames are deferred, but TextKit geometry refinements may refresh the mapping
so the committed preview keeps following momentum. At gesture end, a deferred
frame is positioned from the final source viewport. No gesture-start anchor is
restored over the destination.

Before background completion, reaching the edge of the priority runway may
request another cached window. After completion there is no window edge.

## Height changes

Ultralight reports the block IDs affected by delayed resources or native HTML
state changes. After layout, only those wrappers are remeasured. New pixels,
measurements, total height, mapping, and origin are committed together.

The preview anchors a point in visible content before applying the change and
restores that point afterward. Content outside the viewport may grow or shrink
without moving what the reader sees. If the change races a gesture, publication
waits for gesture end and uses the gesture's final source position.

## Resizing

A resize session captures a source anchor and a preview block anchor. Each pane
resolves its own anchor at the new width. Ultralight reflows off the main
thread; the old coherent frame remains visible until the replacement is ready.
The final width is committed as one geometry, map, scrollbar, and origin.
Background completion restores the full retained presentation at that width.

## Failure behavior

Old revisions and mismatched layout or content versions are rejected. A failed
foreground parse can be retried; a failed background fill can restart after
later successful foreground work. Failures leave the last coherent frame
visible.

## Validation

The regression gate is:

```sh
bash scripts/check-preview.sh
```

It covers the prioritized first frame, complete background publication,
lookup-only deep navigation, parser and presentation failure recovery, edits,
resize anchoring, and delayed height changes during idle and momentum.

## Code guide

- [Native source layout and highlighting](../Sources/Markato/SourceEditor.swift)
- [Foreground/background preparation](../Sources/Markato/EditorWindowController.swift)
- [Preview mapping and publication](../Sources/Markato/FragmentRenderer.swift)
- [Ultralight rendering boundary](../Sources/HTMLPreview/HTMLPreviewView.swift)
- [Retained prepared document](../Sources/MarkdownCore/PreparedDocument.swift)
- [Scroll interpolation](../Sources/MarkdownCore/ScrollLandmarks.swift)
- [Integration checks](../Sources/Markato/IntegrationCheck.swift)
