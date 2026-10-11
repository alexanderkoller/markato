# Retained Comrak edit results

## Cached WebKit window

The current release snapshot is `comrak-cached-window-editfix`. It keeps every prepared HTML fragment and measured preview height in `PreparedDocument`, while WebKit receives only the cached blocks around the viewport. The native tree supplies the approximate whole-document extent and O(log n) prefix position. Background preparation only fills the tree; it no longer republishes the current WebKit window. During live scrolling, replacement starts with four viewports of rendered reserve, and same-revision requests coalesce to one active render plus the latest destination. An edit reuses that already-overscanned window exactly, instead of applying overscan to it a second time.

These values use the same fresh-process open and three-edit protocol as the saved comparisons. Open values are medians of three processes; edit values are medians of nine visible-H1 edits. MacDown 3000 values are the existing measurements and were not rerun.

| Fixture | Operation | Cached window | Prior retained window | MacDown 3000 | Cached-window range |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 KiB dense | open | 122.6 ms | 127.1 ms | 205.8 ms | 120.4–124.9 |
| 64 KiB dense | edit | 30.2 ms | 28.3 ms | 52.7 ms | 27.4–47.0 |
| 1 MiB dense | open | 131.6 ms | 123.9 ms | 2,542.0 ms | 127.0–144.7 |
| 1 MiB dense | edit | 49.1 ms | 69.7 ms | 2,004.1 ms | 33.9–67.2 |
| 8 MiB dense | open | 390.2 ms | 1,322.8 ms | — | 370.2–393.4 |
| 8 MiB dense | edit | 194.3 ms | 539.1 ms | — | 186.7–266.4 |

The 8 MiB startup distribution remains in the former fast mode: all three observations were 370–393 ms. This removes the roughly 1.3 s mode caused by laying out a document-sized WebKit surface. The result is 3.4× faster than the prior retained-window median. At 64 KiB and 1 MiB, startup remains close to constant. The edit-window correction cuts the 64 KiB median from 67.0 to 30.2 ms, the 1 MiB median from 78.3 to 49.1 ms, and the 8 MiB median from 224.8 to 194.3 ms.

The native integration run mounted bounded cached windows while retaining 398 prepared pages in the tree. It passed 149 heading alignments in both directions, a 400-step paced table traversal with zero observed displacement, exact top and EOF navigation, and 600 burst-scroll coverage observations across prose, table and image destinations. Cached two-line movement issued no JavaScript patch.

The earlier retained-window release snapshot is `comrak-retained-window-final`; `comrak-retained-window-final2` adds only a range-boundary correction for edits immediately outside the viewport. `comrak-viewport-final` is its preserved comparison. All parse the complete Markdown revision with Comrak and retain the same Swift block and layout trees. The retained-window build additionally overlaps initial parsing with rope construction, publishes the full prepared viewport-plus-overscan unit, preserves that unit across one revision-changing edit, and patches the displayed DOM in place.

The table uses an alternating A/B run. Open values are medians of three fresh processes. Edit values are medians of nine verified visible-H1 insertions. Ranges include all observations. The offscreen 8 MiB opening measurement has a two-state WebKit/AppKit launch distribution around 0.39 s and 1.3 s in both snapshots; paired medians therefore show parity rather than a stable startup improvement.

| Fixture | Operation | Final | Preserved viewport | Final range | Preserved range |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 KiB dense | open | 127.1 ms | 121.1 ms | 124.6–129.6 | 95.1–121.7 |
| 64 KiB dense | edit | 28.3 ms | 29.2 ms | 19.2–45.9 | 24.9–49.0 |
| 1 MiB dense | open | 123.9 ms | 123.0 ms | 115.6–129.9 | 122.8–124.2 |
| 1 MiB dense | edit | 69.7 ms | 59.1 ms | 52.0–92.3 | 49.9–70.9 |
| 1 MiB sparse | open | 125.6 ms | 119.8 ms | 104.8–128.8 | 107.9–121.2 |
| 1 MiB sparse | edit | 44.4 ms | 60.9 ms | 27.5–58.7 | 28.9–66.4 |
| 8 MiB dense | open | 1,322.8 ms | 1,329.8 ms | 1,311.0–1,375.7 | 390.2–1,343.9 |
| 8 MiB dense | edit | 539.1 ms | 559.2 ms | 268.8–603.8 | 257.0–641.7 |

The edit result is the important regression check. Earlier candidates produced first-edit tails of 3–8 seconds because a revision change expanded the DOM window and invoked a hidden-surface paint fence. The final 8 MiB diagnostic run kept 22 blocks mounted for all three edits. Comrak took 183–286 ms, `PreparedDocument` splicing took 0.3–1.9 ms, source color/layout work stayed near 1 ms, and DOM encoding stayed below 0.21 ms. No edit invoked the paint fence.

## MacDown 3000 comparison

MacDown 3000 version 3000.0.7 remains the external baseline. These are the previously saved measurements; MacDown was not rerun.

| Fixture | Operation | Final AstraMarkdown | MacDown 3000 |
| --- | ---: | ---: | ---: |
| 64 KiB dense | open | 127.1 ms | 205.8 ms |
| 64 KiB dense | edit | 28.3 ms | 52.7 ms |
| 1 MiB dense | open | 123.9 ms | 2,542.0 ms |
| 1 MiB dense | edit | 69.7 ms | 2,004.1 ms |
| 1 MiB sparse | open | 125.6 ms | 762.5 ms |
| 1 MiB sparse | edit | 44.4 ms | 246.0 ms |
| 8 MiB dense | open | 1,322.8 ms | — |
| 8 MiB dense | edit | 539.1 ms | — |

The final build is 1.6×, 20.5× and 6.1× faster to open the three directly comparable fixtures, and 1.9×, 28.8× and 5.5× faster to update them. No saved 8 MiB MacDown result exists. The closest preserved context is a single 4 MiB dense stress run at 47,143.3 ms open and 34,776.9 ms update; it is not an 8 MiB estimate.

## Historical 8 MiB pipeline measurements

The older parser experiments used one exact 8,388,640-byte repeated-paragraph fixture (SHA-256 `6f0f7cb1d515b66b214bfb1d9b041db26a29417417ac73c87c52a253723badb9`). These are retained measurements from the earlier profiling work, not new runs and not end-to-end display latency.

| Pipeline on the exact 8 MiB fixture | Median time | Included work |
| --- | ---: | --- |
| Original Lezer worker, fresh | 6,347.84 ms | full parse and viewport metadata |
| Original Lezer worker, one-character edit | 1,183.95 ms | incremental parse and viewport metadata |
| Retained-document Lezer worker, fresh | 5,673.02 ms | full parse and prepared metadata |
| Retained-document Lezer worker, one-character edit | 448.86 ms | incremental parse and delta metadata |
| Comrak integration probe | 127.42 ms | full parse, dense coordinate map, semantic metadata and full HTML |
| Comrak lightweight parser probe | 97.04 ms | AST and full HTML |
| Hoedown | 26.25 ms | full HTML |
| PEG Markdown Highlight | 407.11 ms | lexical highlight ranges |

The end-to-end 8 MiB app fixture is deliberately different: it is 8,388,717 bytes and contains 43,298 headings so the shared app probe can edit and observe the visible H1. The final alternating run measured 1,322.8 ms open and 539.1 ms edit; the preserved comparison measured 1,329.8 ms and 559.2 ms. The opening distribution is bimodal, so these end-to-end values must not be treated as parser timings. `runs.json` contains the immutable observations and run IDs; the exact historical parser fixture and raw data remain in the October 6–9 research directories.

Validation passed the 26 model tests and six scroll-landmark tests, including randomized rope edits, retained manifest splices, local layout replacement, estimated-region refinement, Unicode/CRLF handling, and parser coverage. Native checks passed IME editing, undo/redo, immediate source paint at the top and after a deep jump, and cached preview jumping. Scrolling through an estimated region may now refine source geometry and replace the viewport preview page; it does not discard the retained document trees or request another parse once background preparation is complete.

## Visible-first source paint experiment

A subsequent debug profile kept the complete Comrak parse and block manifest but materialized source spans and preview fragments only for the requested viewport. Source syntax now uses fixed-metric colors through `NSLayoutManager` temporary attributes, so painting cannot invalidate TextKit geometry. The retained trees and calibrated scrolling path are unchanged.

On the 1 MiB dense fixture, measured opening fell from 2,459.1 ms to 602.6 ms. Source highlighting fell from 582.8 ms to 3.7 ms total, record conversion from 108.6 ms to 13.7 ms, and retained-tree insertion from 126.0 ms to 4.0 ms. The first WebKit patch fell from 10,879 blocks and 2.35 MB to 22 blocks and 4.4 KB; its round trip fell from 176.4 ms to 4.1 ms. Comrak itself remained about 20 ms.

The largest document-sized cost left in this profile is the initial exact TextKit geometry pass at 201.3 ms. Removing that dependence requires a separate change to seed the source layout index with estimates and replace them with measured line geometry around the viewport. It is no longer part of syntax coloring.
