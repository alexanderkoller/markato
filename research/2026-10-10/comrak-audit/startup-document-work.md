# Startup document work

## Implemented path

Startup has one accepted document-sized semantic operation: Comrak parses and converts the complete Markdown revision. The view does not perform another whole-document pass before first display.

`NSDocument` decodes the file once and creates one immutable UTF-16 staging array. `ComrakWorker.prepareInitial` starts on its serial worker using that array while the caller constructs the existing persistent `TextRope`. The rope remains fully edit-ready before the window appears and owns its final leaf storage. TextKit receives the original decoded `String`, so the application does not flatten the rope to recreate it. Rope construction records line breaks and CRLF at the same time.

The first viewport request waits behind the initial Comrak job and queries its prepared document. Its response includes visible syntax and HTML plus the complete lightweight block manifest. `PreparedDocument` installs the manifest in the balanced retained tree. The source pane applies fixed-metric color and traits only to the visible range and seeds estimated geometry outside it. The preview publishes the prepared viewport plus overscan and two structural pending gaps. WebKit therefore receives a bounded block count and payload even when the document is large.

After first view, 100-line native queries populate the same retained tree. They do not reparse Markdown, paint invisible TextKit attributes, or publish a whole-document DOM. A scroll or jump requests its destination at foreground priority through the same parser worker. The complete retained native tree continues to provide stable identities and fast navigation.

No short-document threshold, alternate scrolling algorithm, provisional parser, timer-based admission or hidden whole-document TextKit layout is used. The calibrated scroll mapping is unchanged.

## Edit behavior

Comrak currently reparses the complete revision; this is the remaining size-dependent edit cost. It returns a manifest delta, and the Swift tree splices only the changed interval. Stable semantic IDs preserve fragments, source styles and measured heights for the prefix and suffix. The displayed viewport unit is shifted through the edit and reused for the first publication of the new revision, so a normal visible edit sends one indexed DOM replacement and a suffix offset delta.

The source pane deliberately keeps fixed font metrics. In the instrumented 8 MiB run, Comrak took 183–286 ms, the retained-tree splice 0.3–1.9 ms, visible source highlighting about 0.5 ms, local source layout 0.2–1.3 ms, DOM encoding below 0.21 ms, and ordinary DOM patching about 1.7–2.9 ms in two of three samples. One WebKit round trip took 380 ms, but no edit used the paint fence or changed the 22-block mounted window.

## Controlled release comparison

These numbers come from the final alternating A/B run. Opens are medians of three fresh processes; edits are medians of nine visible-H1 insertions. `comrak-viewport-final` is the preserved comparison and `comrak-retained-window-final` is the measured snapshot. The authoritative `comrak-retained-window-final2` differs only for edits immediately outside a viewport boundary, which the benchmark does not exercise.

| Fixture | Operation | Preserved | Final | Final range |
| --- | ---: | ---: | ---: | ---: |
| 64 KiB dense | open | 121.1 ms | 127.1 ms | 124.6–129.6 |
| 64 KiB dense | edit | 29.2 ms | 28.3 ms | 19.2–45.9 |
| 1 MiB dense | open | 123.0 ms | 123.9 ms | 115.6–129.9 |
| 1 MiB dense | edit | 59.1 ms | 69.7 ms | 52.0–92.3 |
| 1 MiB sparse | open | 119.8 ms | 125.6 ms | 104.8–128.8 |
| 1 MiB sparse | edit | 60.9 ms | 44.4 ms | 27.5–58.7 |
| 8 MiB dense | open | 1,329.8 ms | 1,322.8 ms | 1,311.0–1,375.7 |
| 8 MiB dense | edit | 559.2 ms | 539.1 ms | 268.8–603.8 |

The 64 KiB and 1 MiB opening differences are within run variance. The 8 MiB offscreen benchmark has a bimodal startup distribution: both binaries have produced values around 0.39 s and 1.3 s. In the final paired run, both medians were about 1.32 s. This supports parity and confirms that the new concurrency does not add a stable regression; it does not establish a repeatable opening improvement in the current harness.

The important edit result is that the earlier multi-second tails are gone. The final 8 MiB edit range is 268.8–603.8 ms, comparable to the preserved 257.0–641.7 ms range. The retained Swift work and source-pane work are effectively constant; complete Comrak parsing is now the dominant size-dependent term.

## MacDown 3000 context

MacDown was not rerun. Saved MacDown 3000 measurements are 205.8 ms open and 52.7 ms edit at 64 KiB dense, 2,542.0 ms and 2,004.1 ms at 1 MiB dense, and 762.5 ms and 246.0 ms at 1 MiB sparse. No saved 8 MiB MacDown result exists. Its closest preserved stress result is a non-comparable 4 MiB run at 47,143.3 ms open and 34,776.9 ms update.

## Remaining limits

The first view still includes complete Comrak parsing by design, so startup is `O(n)` even though view preparation is bounded. The present 8 MiB fixture has 43,298 headings; manifest conversion and rope construction therefore remain visible in diagnostics even though WebKit mounts only the top window.

Edit latency also remains `O(n)` because Comrak reparses and converts the complete revision. The retained tree prevents that result from triggering another document-sized Swift, TextKit or WebKit rebuild. Reducing the 8 MiB edit floor below roughly 250 ms would require incremental native parsing or a parser that can safely reparse a bounded syntax region while preserving global Markdown semantics.

The 0.39/1.3 s startup modes warrant a separate harness investigation. The effect appears in both preserved and final signed snapshots and is larger than measured Comrak time. A useful next measurement would record document dispatch, WebKit process readiness and first paint in the release probe without changing application policy.

## Validation

The final code passes 26 MarkdownCore tests, six scroll-landmark tests, the release audit and the full native integration suite. The scrolling test completed 400 paced forward/reverse steps with approximately zero asynchronous displacement across 110 bounded replacements. The test also verifies cached deep navigation after complete background preparation without another parse.
