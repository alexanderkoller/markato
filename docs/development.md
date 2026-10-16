# Developing Markato

Run the commands below from the repository root unless a step says otherwise. For an introduction to the app, see the [README](../README.md).

## Build and run

Xcode with the macOS SDK, Swift 6 or later, Rust, and the Ultralight SDK are required to build (tested with Rust 1.96 and Ultralight 2.0 beta 2). Put the SDK in `Vendor/Ultralight` or set `ASTRA_ULTRALIGHT_SDK` to its root; [Vendor/Ultralight/README.md](../Vendor/Ultralight/README.md) records the exact download and checksum. The resulting app bundles the Ultralight runtime and needs neither Rust nor an external TeX installation.

```sh
bash scripts/build-app.sh
open dist/Markato.app
```

The script builds the pinned Rust static library and release executable, packages the Ultralight libraries, ICU data, preview styles, fonts, and license notices, and applies a local ad hoc signature. It does not install or publish the application. Run `bash scripts/build-native.sh` before building the Swift package directly in Xcode or with `swift build`/`swift test`.

The build also regenerates the application icon from the transparent [1024-pixel master](../App/Branding/Markato-1024.png). `bash scripts/build-icons.sh` produces the standard 16, 32, 128, 256, and 512-point representations at 1× and 2× in `App/Branding/Markato.iconset`, packages `App/Resources/Markato.icns`, and updates the README image. Both debug and release bundles include the icon through `CFBundleIconFile`. Icon generation uses macOS `sips` and Python 3 (standard library only); it does not require `iconutil` or access to IconServices.

Starting the app without another document opens a blank, untitled Markdown document. Passing one Markdown filename opens that file instead. To explicitly open the bundled example document of about 135 KB for development and performance testing, run:

```sh
bash scripts/open-sample.sh
```

The launcher starts a separate instance of the release app, so it also works when another Markato instance is already running. The equivalent direct command is `dist/Markato.app/Contents/MacOS/Markato --sample`.

## Validation

Install the Ultralight SDK as described in `Vendor/Ultralight/README.md`, or set
`ASTRA_ULTRALIGHT_SDK` to an extracted SDK, before running the Swift checks.

```sh
bash scripts/build-native.sh
cargo test --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
cd Parser
npm ci
npm test
```

Native integration checks require a graphical Mac session and the separate debug app:

```sh
bash scripts/build-app.sh debug
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test
dist/debug/Markato.app/Contents/MacOS/Markato --smoke-test
```

The default integration check verifies a bounded Ultralight first view, presentation and parser recovery without hiding the committed view, cached deep navigation without reparsing, a retained-tree edit, resize, and return-to-top scrolling. Parser failures receive one cancellable automatic retry; repeated failures leave the last good preview visible and expose a Retry button. Focused flags retain the source-layout and jump checks. Failed checks exit with a nonzero status. The smoke check writes a bitmap of the example window to `/private/tmp/markato-smoke.png`.

The prototype has not established same-frame presentation at 60/120 Hz or complete behavior equivalence with the earlier Markdown dialect. In particular, try complex nested lists and quotes, very large paragraphs and table cells, composed input, rapid scrolling and continuous resizing.

## Timing diagnostics

Timing diagnostics, native test runners and test-only counters are compiled only in debug builds. Release builds omit them entirely. The debug app is packaged at `dist/debug/Markato.app`, separately from `dist/Markato.app`. Release packaging starts from a fresh allowlisted bundle and audits symbols, strings and resources with `scripts/check-release.sh`; a failed audit stops packaging. The bundled example remains a normal product resource.

Choose **Help → Start Timing Diagnostics**, reproduce the scrolling or editing problem,
then choose **Help → Stop Timing Diagnostics** and **Help → Save Timing Report…**.
Starting another recording clears the previous one. Recording is off by default;
the most recent 20,000 completed events are retained in memory, with no file I/O
on scrolling callbacks. The exported JSON includes a timestamped event timeline,
counts, medians, p95/max durations, queue delays, source/preview positions, cache
and viewport sizes, and system/app metadata. It contains no document text or file
paths. Exporting a report does not stop an active recording.

Measurements distinguish source layout/highlighting, viewport preparation, cache
updates, worker queue waits, Comrak/input/record work, KaTeX, HTML presentation, DOM layout,
and image preparation. A roughly 10 Hz probe samples main
queue dispatch delays. These measurements help distinguish processing delays from
discontinuous positioning; they do not measure actual displayed-frame latency.
Native intervals use a monotonic clock. Nested interval totals overlap.

To include startup in a recording, launch the executable with `--diagnostics`.
The instrumented integration check verifies event collection and JSON export:

```sh
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --diagnostics
```

Its report is written to `/private/tmp/markato-ultralight-integration-timings.json`. A focused `--integration-layout-index` check independently compares the cached index with native glyph coordinates after local and coalesced edits, Unicode/CRLF insertion, deletion, append, typography, resize, and model-driven replacement.

## Parser maintenance

Code-fence preview highlighting uses Syntect 5.3.0 with two-face 0.5.2+bat-0.26.1 grammars and generated CSS. See [Code-fence highlighting](highlighting.md) for language coverage, limits, fixtures, and benchmarks. The native regression gate includes `--integration-highlighting`.

Mermaid SVG rendering uses pinned rusty-mermaid 0.2.0 on the parser worker. See [Mermaid rendering](mermaid.md) for compatibility, test documents, native validation, and benchmarks. Its dependency notices are packaged alongside the existing Comrak notices.

Comrak 0.55.0 is vendored with a small source-coordinate correction documented in `Native/vendor/comrak/ASTRA-PATCH.md`. The Rust dependency versions are pinned in `Native/Comrak/Cargo.lock`. Build the native adapter with `bash scripts/build-native.sh`. The bundled KaTeX JavaScript and third-party notices are checked in. To rebuild KaTeX after changing `Parser/math.mjs`:

```sh
cd Parser
npm ci
npm run build
```

The application has no external Swift package dependencies. The Ultralight SDK is installed separately as described in `Vendor/Ultralight/README.md`. Node library versions are pinned in package-lock.json. Comrak, Rust dependency and KaTeX license notices are packaged in the application.

The complete preview regression gate runs debug and release core tests, packages and audits the release app, builds the separate debug app, and exercises prioritized first presentation, complete background presentation, editing, resizing, height changes, sustained scroll throughput, and lookup-only deep navigation. Run it from a macOS graphical session:

```sh
bash scripts/check-preview.sh
```

Presentation geometry messages are observations rather than publication commands. Superseded, malformed, unpainted, or incomplete presentations cannot commit. Font, width, HTML, metadata, and asset-directory changes use the same request identity and commit path.
