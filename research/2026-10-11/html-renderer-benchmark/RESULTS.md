# HTML renderer benchmark results

## Decision

Ultralight is the only tested replacement that materially improves first view,
large-document deep rendering, and visible edits while preserving full HTML,
CSS, and in-place DOM mutation. It is a substantial constant-factor improvement
over WKWebView, but it does not make a
complete tall document cheap: the 8 MiB source still takes 1.05 s to first
pixels, uses 1.37 GB RSS, takes 86 ms to materialize a deep viewport, and takes
62 ms to show a visible text edit.

Changing the engine therefore does not remove the need for a bounded document
surface. If AstraMarkdown keeps a complete 8 MiB DOM, Ultralight is the best
candidate for a product-level prototype. If the target remains nearly
document-size-independent first view and sub-frame scrolling/edit latency, keep
the existing block tree and virtualize the HTML surface. A native retained
renderer built directly from that tree is the other credible long-term path.

## Workload

The benchmark concerns the preview panel. It excludes Markdown parsing and gives
every engine the same complete Markdown-derived HTML with per-block wrappers,
controlled CSS, a fixed system-font stack, 560 × 760 viewport, and no network
resources. Source sizes and generated HTML sizes are:

| Markdown source | HTML input | Blocks |
|---:|---:|---:|
| 65,569 B | 117,784 B | 685 |
| 1,048,632 B | 1,881,252 B | 10,879 |
| 8,388,717 B | 15,089,482 B | 86,597 |

“First view” is measured from cold view construction through a completed first
frame. “Deep view” scrolls to both the midpoint and end, waits for a rendered
frame, and reports the slower operation. “Visible edit” replaces text in the
top visible block and waits for the updated frame. Values are medians of five
fresh processes after an unreported warm-up, except AffineUI at 1 MiB (`n=3`)
and explicit time/memory stops. The exact procedure is in `PROTOCOL.md` and the
input hashes are in `fixtures/manifest.json`.

## End-to-end results

All values are milliseconds. A dash means the engine did not provide the
required operation or the run was stopped before a safe result.

### Cold first view

| Engine | 64 KiB | 1 MiB | 8 MiB |
|---|---:|---:|---:|
| WKWebView | 206.0 | 313.3 | 1,293.4 |
| Ultralight | **49.1** | **152.1** | **1,052.2** |
| Sciter | 186.4 | 784.6 | resource stop |
| litehtml¹ | 27.9 | 1,686.6 | resource stop |
| AffineUI¹ | 44.7 | 7,376.3 | >60 s timeout |

### Deep view and visible edit

| Engine | 64 KiB deep | 64 KiB edit | 1 MiB deep | 1 MiB edit | 8 MiB deep | 8 MiB edit |
|---|---:|---:|---:|---:|---:|---:|
| WKWebView | 1.2 | 1.2 | **1.4** | 2.5 | 152.4 | 89.0² |
| Ultralight | 1.3 | **0.1** | 2.6 | **0.9** | **86.3** | **61.5** |
| Sciter | 25.1 | 24.8 | 25.6 | 93.8 | — | — |
| litehtml¹ | 1.1 | unsupported | 39.8 | unsupported | — | unsupported |
| AffineUI¹ | — | 37.5 | — | 7,451.6 | — | — |

¹ litehtml and AffineUI used fixed approximate font metrics and a no-op painter.
Their parse/layout/traversal numbers are lower bounds and are not pixel-complete
times comparable to the first three engines. The poor scaling is real despite
that advantage.

² WKWebView’s 8 MiB edit distribution is bimodal: 87–89 ms in three runs and
211–222 ms in two. The median hides the slow mode already seen in the app.

### Process memory

| Engine | 64 KiB | 1 MiB | 8 MiB |
|---|---:|---:|---:|
| Ultralight | 82 MB | 234 MB | 1,371 MB |
| Sciter | 121 MB | 539 MB | not run³ |
| litehtml | 48 MB | 705 MB | not run³ |
| AffineUI | 35 MB | 337 MB | timed out |
| WKWebView host only⁴ | 66 MB | 77 MB | 130 MB |

³ The 1 MiB observation projected beyond the 4 GiB safety ceiling at 8 MiB, so
the 8 MiB process was deliberately not launched.

⁴ `getrusage(RUSAGE_SELF)` cannot see WebKit’s content and GPU processes. This
row is retained as host-process evidence and must not be compared with the
in-process engines.

## Option-by-option assessment

### WKWebView

The minimal harness reproduces the application’s tall-document behavior without
the rest of AstraMarkdown: 1.29 s first view, 152 ms deep materialization, and a
bimodal 8 MiB edit. This localizes the remaining size sensitivity to the full
WebKit document rather than Comrak or the synchronized block tree. WKWebView is
still the best-tested and lowest-risk implementation, and it performs very well
through 1 MiB.

### Ultralight 2.0.0-beta.2

Ultralight provides the needed native DOM mutation API, can run with JavaScript
disabled, and was the fastest pixel-producing implementation at every size. Its
8 MiB costs still scale with the full DOM, and its RSS is too large to call the
problem solved. The SDK identifies its internal engine as WebKit
615.1.18.100.1, so this replaces WKWebView's embedding, process, and rendering
stack rather than changing to a different layout-engine family. The tested free
SDK is also a reduced build: the vendor lists a
60 FPS cap and limits free commercial use to companies below both $200,000
turnover and funding. The paid SDK is licensed per title. See
[Ultralight pricing](https://ultralig.ht/pricing).

### Sciter 6.0.5.1

Sciter consumes the complete HTML and supports native in-place DOM mutation. A
current universal macOS build exists; the stale GitHub archive is not the active
project. The current release is documented in the
[Sciter GitLab tags](https://gitlab.com/sciter-engine/sciter-js-sdk/-/tags).
Its 1 MiB first view is 2.5× slower than WKWebView, a visible edit is 94 ms, and
RSS reaches 539 MB. The projected 8 MiB memory use stopped that run. It is not a
performance replacement for this workload.

### litehtml

litehtml is intentionally a layout engine whose host supplies fonts and every
drawing operation; its own README says it is not fully HTML/CSS compatible and
does not recommend it as a full browser engine. More decisively, its public
document lifecycle finalizes a tree once and instructs callers to build a new
document to rebuild it. There is no supported incremental text mutation path.
At 1 MiB, parsing takes about 1.58 s, RSS is 705 MB, and even a clipped deep draw
traversal takes 40 ms before real raster work. See the
[litehtml repository](https://github.com/litehtml/litehtml).

### AffineUI

AffineUI accepts raw HTML and exposes a direct text update, but that update
invalidates global layout in this workload. The 1 MiB initial layout takes 7.25
s and the one-block edit takes 7.45 s end to end even with approximate fonts and
no raster backend. The project itself labels the current implementation alpha
and advises against shipping it to customers. See the
[AffineUI repository](https://github.com/affineui/affineui).

### Servo

Servo is included in the evaluation but not assigned a misleading application
timing. It has a WebView API and ships a macOS aarch64 browser snapshot, but the
project says the stable C wrapper needed to consume Servo as a prebuilt shared
library is still being designed. Today a native macOS integration requires
building and binding the large Rust engine rather than dropping in a supported
view library. A servoshell timing would measure a browser application with a
different host and would not test AstraMarkdown’s required in-place DOM API.
The project’s current status is described in the
[Servo embedding update](https://servo.org/blog/2026/07/31/june-in-servo/)
and [download page](https://servo.org/download/). Revisit it when the C ABI is
published and supported.

### Glint

Glint is included but cannot run this benchmark. Its v0.1 API constructs its own
element tree; the vendor roadmap lists a real HTML parser as planned. Manually
translating Comrak output into a proprietary scene tree would benchmark a new
renderer architecture rather than an HTML view replacement. See the
[Glint v0.1 documentation](https://superkraft.io/docs) and
[Glint roadmap](https://superkraft.io/roadmap).

## Interpretation for AstraMarkdown

The results separate two questions. Ultralight shows that WebKit carries a
meaningful constant overhead: at 1 MiB it saves about 161 ms at startup, and at
8 MiB it saves about 241 ms. No tested complete-DOM engine makes the main costs
independent of document size. The lighter layout engines scale worse because
they lay out or traverse the full tree, and two run out of a reasonable memory
budget before 8 MiB.

The existing synchronized document tree remains valuable. It already supplies
stable ordering, block identity, fast range replacement, cached source/preview
fragments, and height information. A bounded HTML surface can use those data
directly and keep a logical full-document scroll range outside the renderer.
Once cached blocks are ready, replenishing a 24-viewport window is tree lookup
plus insertion of bounded content; no renderer in this comparison offers a
full-document shortcut with the same asymptotic behavior.

The next implementation decision should therefore be one of:

1. keep WKWebView and finish the bounded-surface/full-cache transition;
2. prototype the same bounded surface on Ultralight if its closed-source license
   and memory profile are acceptable; or
3. render the existing block tree directly with TextKit/Core Text plus a native
   retained preview renderer, accepting a deliberately smaller CSS subset.

Replacing WKWebView with Ultralight while retaining one complete DOM is a useful
constant-factor optimization, not the architecture that meets the stated
latency goal.

## Bounded Ultralight follow-up

A follow-up probe tested the proposed retained-tree architecture directly. It
mounted a fixed window of the existing semantic block wrappers, used Ultralight's
native DOM API with JavaScript disabled, retained overlapping DOM nodes during
an adjacent refill, and performed a CPU render after every operation.

The 384-block window was approximately 22.8 viewports tall. Five fresh processes
were measured for each document/window pair; a separate seven-run sample measured
local scrolling.

| Source document | Document blocks | First bounded view | Local scroll | 48-block refill | Cold deep window | Visible edit |
|---:|---:|---:|---:|---:|---:|---:|
| 64 KiB | 685 | 39.2 ms | 1.27 ms | 2.0 ms | 3.4 ms | 0.12 ms |
| 1 MiB | 10,879 | 39.2 ms | 1.28 ms | 1.9 ms | 3.8 ms | 0.11 ms |
| 8 MiB | 86,597 | 38.6 ms | 1.26 ms | 1.9 ms | 3.9 ms | 0.12 ms |

The first-view interval includes navigating to a document containing the fixed
HTML/CSS shell and initial window. The persistent-shell path was measured
separately: inserting and rendering the first 384 blocks into an already loaded
empty shell took 1.23--1.24 ms across the three document sizes, with a 1.38 ms
observed maximum. The shell can be prewarmed while Comrak parses. Every overlap
identity check passed and measuring all 384 mounted block heights took about
0.04 ms.

Window-size runs covered approximately 7.6, 15.2, 22.8 and 30.3 viewports. A
cold deep-window replacement increased from roughly 1.3 ms at the smallest to
4.5--5.5 ms at the largest, while remaining flat across total document sizes.

The allowed visible-element dependency was tested separately. Loading one
complete visible table took 30.5 ms at 100 rows, 36.7 ms at 1,000 rows, and
133.0 ms at 10,000 rows. The architecture therefore removes dependence on total
document size while retaining work proportional to complete visible semantic
elements.

These results support a bounded Ultralight module rather than a full-DOM engine
replacement. The architecture and integration gates are specified in
`docs/ultralight-preview-architecture.md`.

## Reproducibility and limits

The benchmark ran on macOS 26.6.2 arm64 with Xcode 27.0. Pinned revisions and
SDK hashes are in `VERSIONS.json`; per-run JSON is in `raw/`; derived medians and
ranges are in `summary.json`; harnesses are in `src/`.

WebKit uses `takeSnapshot` as its pixel barrier. JavaScript is used only by the
harness to set scroll position, read height, and mutate text. Ultralight uses
its CPU bitmap renderer with JavaScript disabled; GPU acceleration may reduce
paint time but does not remove parse, DOM, or layout work. Sciter uses
`SciterUpdateWindow` as its frame barrier. The litehtml and AffineUI harnesses
measure engine work with no-op painters, as marked in the tables.

The fixtures are intentionally prose-dominant and contain no images or external
assets. They model the tall-document bottleneck and node counts well, but they
do not predict the additional cost of image-heavy documents, large tables, or
complex syntax-highlighting markup.
