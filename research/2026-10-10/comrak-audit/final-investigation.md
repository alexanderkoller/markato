# Comrak startup and retained-edit investigation

## Final design

Comrak performs one complete parse and conversion for each document revision. The complete lightweight block manifest seeds the existing balanced `PreparedDocument` tree. Source geometry remains in `LayoutIndex`; the calibrated scrolling equations were not changed. HTML and syntax records are materialized into retained nodes for the visible viewport plus overscan, then filled in the background.

Semantic block IDs stay stable when Comrak proves that a block is unchanged. They are the join keys between the native manifest, retained Swift nodes, cached fragments and measured heights, and the DOM. Temporary parse objects may use fresh identity. Pending gaps use structural IDs derived from adjacent semantic blocks, so an offset shift does not invalidate them and different viewport windows do not collide.

On open, the decoded string is converted to one immutable UTF-16 staging buffer. `ComrakWorker.prepareInitial` reads that buffer on its worker while the caller builds the persistent edit rope from it. Rope leaves own their final storage; the staging buffer is only shared read-only during construction. The decoded `String` is retained for initial TextKit population, and CRLF detection is folded into rope construction.

The first preview publication contains the prepared viewport plus its overscan window and pending regions before and after it. The complete native tree is the navigation authority; the whole document is not mounted in WebKit. A scroll or jump queries the already parsed Comrak document, stores the result in the same retained nodes, and publishes another bounded window. Background preparation populates the retained tree without eagerly painting invisible source attributes or repeatedly mounting the entire DOM.

For an edit, Comrak reparses the complete revision and returns a block-manifest delta. `PreparedDocument.apply` splices only that interval and lazily shifts the retained suffix. The displayed presentation window is transformed by the source edit and reused for the first publication of the new revision. A normal one-block edit therefore sends one indexed DOM replacement plus a suffix offset shift. Later same-revision scrolling resumes the existing viewport-plus-overscan path.

The source pane retains the fixed-metric styling decision. Source highlighting changes color and traits without changing font size or line geometry. In the 8 MiB diagnostic run, visible highlighting took about 0.5 ms and local source layout 0.2–1.3 ms.

## Regressions found and fixed

1. Whole-document DOM publication made WebKit geometry and process scheduling proportional to block count. It was removed from the edit and scrolling paths.
2. Publishing only the literal visible blocks discarded already prepared overscan and caused avoidable preview replacements. Publication now uses the complete prepared request unit.
3. Offset-based pending IDs changed after insertion; simple positional IDs then collided across viewport windows. Structural gap IDs are stable under shifts and distinct across windows.
4. A first edit could expand the mounted window from 22 to 38 blocks. That disabled the indexed patch and forced a hidden-surface replacement. In the diagnostic 8 MiB run, Comrak took 250 ms and the tree splice 0.54 ms, while the accidental WebKit replacement took 1.17 s plus a 2.74 s paint fence. Preserving the presentation window across exactly one revision change removes that work.
5. `WKWebView.takeSnapshot(afterScreenUpdates:)` was being used after an in-place edit. Indexed edits now commit after measured geometry; hidden scrolling replacements retain the paint fence.
6. Edit-time identity recovery hashed every old source block and rendered HTML even though edit coordinates already identify retainable blocks. Content hashing is now reserved for adopting a separately parsed identical document.
7. Initial parsing and rope construction each materialized the decoded string independently. They now read one immutable UTF-16 staging buffer concurrently.
8. Invisible syntax was applied to TextKit in background batches. Syntax records remain indexed and are applied only when their range is visible.

## Crash classification

Saved historical crashes from `PreviewPane.makeMap` and `SourceEditor.applyDeferredHighlights` were unowned-reference failures; asynchronous callbacks now capture their owners weakly. Debug precondition reports are deliberate integration failures from rejected experiments. Recent `_RegisterApplication` aborts occurred before application code when a GUI binary was launched in the restricted command sandbox; approved native launches of the same binaries succeed.

## Validation

The final build passes 26 MarkdownCore tests, six scroll-landmark tests, the production release audit, and the native integration suite. The integration run covers editing, undo/redo, encoding and CRLF, source and preview alignment, resizing, tables, images, KaTeX, cached jumps, forward/reverse scrolling and burst scrolling. Its paced 400-step replacement test observed a peak asynchronous displacement of approximately `2.3e-13` points across 110 replacements.

The authoritative final snapshot is `comrak-retained-window-final2`; `comrak-retained-window-final` is the measured snapshot and differs only in the range-boundary handling for edits immediately outside the viewport. `comrak-viewport-final` is the preserved comparison. Raw app snapshots, immutable run records, probe output, diagnostic timing reports and rejected experiments remain under `app-benchmark`. MacDown 3000 values are saved prior measurements and were not rerun.
