# How synchronized scrolling works

AstraMarkdown keeps source editing, Markdown preparation, and preview painting separate. Scrolling reads already prepared state; it does not reparse Markdown or rebuild the source document merely because the viewport moved.

## State ownership

The editor retains the complete source text. Its `LayoutIndex` uses one global source coordinate system and contains a mix of exact TextKit line measurements and estimated gaps. Estimates make distant navigation possible without eagerly laying out the whole document. When TextKit measures a region, those exact lines replace the estimate in place.

`PreparedDocument` retains the ordered Markdown block manifest, cached HTML, syntax coverage, source layout, and preview-height estimates. Stable block IDs let edits preserve unaffected cached content and measured heights.

The preview owns two viewport-sized Ultralight surfaces. One committed presentation contains the content revision, mounted source range, measured preview geometry, scroll map, and source geometry revision. A pending request cannot partially overwrite that committed state.

## Preparing content

The foreground request covers the visible source range plus overscan. Background preparation then fills cache gaps from the beginning of the document. If navigation reaches an unprepared destination, the foreground request takes priority.

Comrak parses a complete document initially. For an eligible local edit, the native adapter reparses the affected top-level blocks with unchanged guards and splices the verified result into the retained manifest. Reference-dependent, coalesced, or propagating edits fall back to a complete parse.

Prepared cache coverage and displayed coverage are different. Reaching cached content can require a new bounded preview presentation, but it does not require another Markdown parse.

## Mapping source to preview

Headings and standalone images are sparse landmarks. Each landmark pairs an exact source position with measured Ultralight geometry. Document boundaries provide the endpoints.

The map converts landmark positions into viewport origins and linearly interpolates between adjacent points:

```text
fraction = (sourceOrigin - source0) / (source1 - source0)
previewOrigin = preview0 + fraction * (preview1 - preview0)
```

Points are ordered and preview coordinates are kept monotone, so forward source movement cannot move the preview backward. Near document boundaries, the reading reference transitions between the top, middle, and bottom of the viewport so both panes can reach their true endpoints.

An estimate may position a distant source destination before TextKit has measured it. A new synchronized map is committed only from a coherent presentation; refinement updates the source geometry revision and triggers the normal map rebuild.

## Moving the viewport

The native source scroll view owns ordinary vertical input. Each bounds change evaluates the committed map and moves the preview clip. Vertical input over the preview is forwarded to the source. Horizontal preview gestures remain inside Ultralight.

During a covered live-scroll gesture, the committed map is frozen. Background preparation may continue privately, but an unrelated presentation cannot change the scrolling gain mid-gesture. Crossing the mounted window reserve requests another cached window. An unprepared destination shows loading until its content is ready.

When the source has no vertical scroll range but the preview does, the preview may scroll independently. Inspectors also use independent scrolling.

## Publishing a preview

A request captures its revision, entries, font size, asset base, and width. Ultralight reconciles stable section IDs, lays out the bounded document, returns geometry, and paints a bitmap. The controller commits the request only if it is still current and covers the destination.

The visible surface can be updated when the request is compatible with its current content. Otherwise, the spare surface is prepared and swapped in only after layout and painting succeed. Resource-driven repaints use the same surface without changing content identity.

No page JavaScript participates in rendering or measurement.

## Editing and failure behavior

Edits invalidate the affected retained manifest interval and advance the document revision. Results from older revisions are ignored. Unchanged blocks retain their IDs, cached HTML, measured heights, and shifted source coordinates.

A failed foreground parse clears its request token, allowing the same viewport to be requested again. A failed background batch clears its revision token so later successful foreground work can restart cache filling. The last coherent presentation remains visible while replacement work is pending.

## Validation

The main checks are:

```sh
bash scripts/build-native.sh
cargo test --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
bash scripts/build-app.sh debug
dist/debug/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --integration-test
dist/debug/AstraMarkdown.app/Contents/MacOS/AstraMarkdown --integration-layout-index
```

The default integration check covers the bounded first view, failed presentation recovery, automatic and manual parser recovery while retaining the committed view, cached deep navigation, EOF edits, resize, and return to the top. The layout-index check compares refined cached positions with independent native glyph coordinates after edits and width changes.

These checks establish state ownership, geometry consistency, and parser behavior. They do not prove compositor timing on every physical display.

## Code guide

- [Native source layout and highlighting](../Sources/AstraMarkdown/SourceEditor.swift)
- [Foreground/background preparation](../Sources/AstraMarkdown/EditorWindowController.swift)
- [Preview mapping and publication](../Sources/AstraMarkdown/FragmentRenderer.swift)
- [Ultralight rendering boundary](../Sources/HTMLPreview/HTMLPreviewView.swift)
- [Retained prepared document](../Sources/MarkdownCore/PreparedDocument.swift)
- [Scroll interpolation](../Sources/MarkdownCore/ScrollLandmarks.swift)
- [Native Comrak adapter](../Native/Comrak/src/lib.rs)
- [Integration checks](../Sources/AstraMarkdown/IntegrationCheck.swift)
