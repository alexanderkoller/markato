# Syntect and two-face preview benchmark

Measured on 2026-10-12 using Apple M4 Pro, macOS 26.6.2, Rust 1.96.0, Syntect 5.3.0, two-face 0.5.2+bat-0.26.1, and the release profile. The installed bundle contains 220 grammar entries, including embedded and helper syntaxes. These measurements cover the Rust record pipeline: UTF-16 decoding, Markdown parsing, token rendering, record allocation, and result freeing. They exclude process launch, Swift scheduling, DOM layout, and painting. UTF-16 inputs are prepared before timing.

Each warm case receives 200 ms of warmup and 101 samples in one process. The plain baseline changes fence language labels to `text`; it keeps code contents while skipping token parsing. The original fixture includes twelve languages; `extended` includes Swift, TypeScript, TSX, Kotlin, Dart, TOML, Dockerfile, and Typst. The stress fixture includes one hundred multiline Python fences. Threshold fallback is measured at 5,001 lines. Plain prose does not load the grammar bundle.

| Case | Median (ms) | p95 (ms) | Plain baseline median (ms) | Prior default-bundle median (ms) |
| --- | ---: | ---: | ---: | ---: |
| languages | 0.586 | 0.602 | 0.023 | 0.532 |
| extended | 0.636 | 0.646 | 0.018 | — |
| stress_100 | 6.414 | 6.720 | 0.234 | 6.334 |
| python_100_lines | 2.152 | 2.169 | 0.012 | 2.233 |
| python_1000_lines | 21.288 | 21.773 | 0.120 | 22.241 |
| over_line_limit | 0.256 | 0.265 | 0.216 | 0.256 |
| prose_64k | 0.982 | 1.052 | — | 1.000 |

Ten fresh processes measure the first Python fence internally, including grammar initialization: median 2.540 ms, range 2.459–2.849 ms. The prior default bundle measured a median of 1.775 ms. The larger bundle adds initialization work once per parser process. OS caches may persist between processes. The single cold row in `results.csv` is a separate observation; use `cold.csv` for the repeated startup distribution.

Warm timings for the existing workloads remain close to the prior measurements. The earlier results were collected separately on the same machine, so small differences should not be read as a controlled speedup or regression. The new fixture had no highlighted baseline under the old grammar bundle.

Highlighting cost grows with tokens and lines. The 1,000-line Python case takes about 21 ms on this machine; it is not representative of every grammar or input. Limits preserve full escaped code while avoiding highlighting oversized fences. These parser measurements do not establish whole-app frame latency.

## Reproduce

From the repository root:

```sh
MACOSX_DEPLOYMENT_TARGET=15.0 cargo build --release --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak --example highlight_benchmark
python3 benchmarks/highlighting/measure.py
bash scripts/check-preview.sh
```

The Python runner collects warm results and ten cold-process observations without timing launch overhead. Raw data: [results.csv](results.csv), [cold.csv](cold.csv), and [environment.json](environment.json). The environment file records fixture and implementation hashes. Prior default-bundle measurements are preserved in [syntect-defaults-results.csv](syntect-defaults-results.csv), [syntect-defaults-cold.csv](syntect-defaults-cold.csv), and [syntect-defaults-environment.json](syntect-defaults-environment.json).

## Validation

The [full regression log](validation.log) records 20 passing Rust tests, 38 Swift debug tests, 36 Swift release tests, KaTeX checks, the release audit, and native Mermaid, highlighting, and general preview integration checks. Injected parser failures in the log are expected recovery tests. Stylesheet regeneration matches the checked-in CSS; Rust formatting and diff whitespace checks pass.

The eight new grammars and common aliases produce token spans. Swift bridge checks compare exact code text for Unicode, HTML, TSX markup, and Typst. The native highlighting check verifies Swift and Typst token classes, colored pixels, literal HTML, math and Mermaid coexistence, resize, edit, undo, and redo. The [native preview screenshot](native-preview.png) was visually inspected in light mode. Dark CSS is generated from Syntect’s bundled theme; a native dark-mode painting check was not performed.

The release bundle contains both the two-face license and its required syntax acknowledgements. See [the integration guide](../../docs/highlighting.md), [complete grammar list](../../docs/supported-languages.txt), and [test documents](../../Tests/fixtures/highlighting/).
