# Mermaid rendering

Markato renders fenced `mermaid` blocks to SVG using pinned rusty-mermaid 0.2.0. Rendering runs on the existing Markdown parser worker. It works offline and requires no Node.js, browser process, JavaScript runtime, or additional installation.

````markdown
```mermaid
flowchart LR
    Source[Markdown source] --> SVG[SVG diagram]
    SVG --> Preview[Live preview]
```
````

The language must be lowercase `mermaid`. Backtick and tilde fences work, including fences nested in quotes and lists. Additional fence info is ignored after the first language token. CommonMark also recognizes an unfinished fence at the end of a document, allowing preview while typing.

## Rendering and compatibility

Comrak identifies code fences and retains their normal fenced-code kind, source ranges, and syntax spans. The adapter sends the literal diagram body through rusty-mermaid's parse/layout pipeline and SVG backend. It percent-encodes the completed SVG into a data-URL image, with explicit intrinsic dimensions. SVG image documents isolate repeated marker IDs and keep diagram markup outside the preview DOM. Preview JavaScript remains disabled. Each image scales down to the available width while retaining its aspect ratio.

Diagrams use the renderer's light theme on a white panel, including when the editor uses dark appearance. Theme configuration, interactive diagram links, HTML labels, and exact Mermaid.js rendering parity are not provided by this integration. rusty-mermaid strips HTML tags from flowchart labels and supports line breaks; text measurement uses its native approximation rather than browser font layout. Its parsers can accept partial syntax, so an unfinished diagram may render instead of displaying an error.

The checked corpus exercises flowcharts, sequence, state, class, entity relationship, pie, mindmap, Gantt, timeline, Git graph, XY chart, Sankey, quadrant, and journey diagrams. rusty-mermaid includes additional families, but this corpus does not establish compatibility with every family or every Mermaid.js construct.

Syntax errors, unknown diagram types, empty output, invalid dimensions, and caught renderer panics show a short message plus the escaped diagram source. The surrounding document continues rendering. Each diagram is limited to 64 KiB of UTF-8 input and 1,000 lines; larger fences show their source. These input limits bound common accidental workloads, not worst-case graph layout time. Rendering is synchronous within the background parser call; an individual render is not interruptible.

There is no additional renderer cache or persistent Rust state. Swift's existing retained blocks reuse prepared HTML and limit ordinary edits to a guarded source region. A complete fallback parse renders its Mermaid blocks again.

## Test documents

Open these files in Markato for inspection. Rust and Swift tests read the same fixtures directly from the repository; test documents are not packaged into the release app.

| Document | Coverage and expected result |
| --- | --- |
| [families.md](../Tests/fixtures/mermaid/families.md) | 14 representative diagram families; every fence should render. Inspect labels, arrowheads, legends, joins, and hierarchy. |
| [layout.md](../Tests/fixtures/mermaid/layout.md) | Eight diagrams, repeated markers, wide graphs, quotes, lists, tilde fences, extra info, Unicode, line breaks, tables, math, and ordinary code. Resize to verify proportional scaling. |
| [errors.md](../Tests/fixtures/mermaid/errors.md) | Five failures followed by a valid diagram. Source HTML must remain text and the final paragraph must render. |
| [stress.md](../Tests/fixtures/mermaid/stress.md) | 100 unique diagrams interleaved with headings and prose. Scroll, resize, edit near both ends, undo, and redo. |
| [native.md](../Tests/fixtures/mermaid/native.md) | Compact native integration fixture: repeated flowcharts, a sequence, a failed diagram, and KaTeX. |

For manual editing checks, remove a diagram header, restore it, change a label to include an emoji, and change a fence's language between `mermaid` and `text`. Verify that errors stay local, diagram/code switching works, and neighboring content stays associated with its source. In the layout document, narrow the preview, scroll to the wide diagram, and restore the original width. In the stress document, navigate to diagram 99 and back to diagram 0 before editing each.

## Automated checks

Build the native library before running Swift tests:

```sh
bash scripts/build-native.sh
cargo test --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
```

Rust tests check fence recognition, nested rendering, literal fallback escaping, Unicode/CRLF source coordinates, all representative families, input limits, and the 100-diagram document. Swift tests additionally validate every fixture SVG as XML, verify Mermaid and KaTeX together, compare a regional label edit with a fresh parse, and check recovery without resetting the parser worker.

The native check requires a graphical Mac session:

```sh
bash scripts/build-app.sh debug
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-mermaid
```

It verifies actual image geometry and painted pixels, repeated diagrams, coexistence with KaTeX, proportional resizing, recovery from an invalid header, undo, and redo. It writes `/private/tmp/markato-mermaid-native.png` for visual inspection. The full `bash scripts/check-preview.sh` gate includes this check alongside the existing parser, debug/release core, release packaging, and native preview checks.

## Benchmarks

See [benchmark results and reproduction instructions](../benchmarks/mermaid/README.md). The harness measures raw native SVG generation, the complete native record pipeline including SVG data-URL encoding, and a same-content code-fence baseline. These timings exclude app startup, preview image decoding and painting, Swift record adoption, and screen presentation.
