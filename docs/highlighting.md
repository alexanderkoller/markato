# Code-fence highlighting

The preview renders ordinary code fences with Syntect 5.3.0 and the pinned two-face 0.5.2+bat-0.26.1 grammar bundle through a custom Comrak adapter. Language labels select the bundled grammar; token spans receive CSS classes, and the preview applies InspiredGitHub in light mode and base16-ocean.dark in dark mode. Rendering runs in the Rust parser worker and requires no JavaScript. The source editor retains its existing Markdown highlighting.

## Language selection and fallback

Use a fenced language token such as `rust`, `python`, `javascript`, `json`, `html`, `css`, `sql`, `bash`, `yaml`, `cpp`, `go`, or `xml`. Syntect also accepts aliases from its bundled syntax set. The [complete installed grammar list](supported-languages.txt) includes names and extension aliases. Regenerate it with:

```sh
cargo run --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak --example highlight_styles -- --list > docs/supported-languages.txt
```

The two-face bundle includes Swift, TypeScript/TSX, Kotlin, Dart, TOML, Dockerfile, and Typst alongside the original languages. Use `swift`, `typescript`/`ts`, `tsx`, `kotlin`/`kt`, `dart`, `toml`, `dockerfile`, or `typst`/`typ` as fence labels. Typst fences display highlighted source.

Unknown labels, unlabeled fences, and explicit `text`, `txt`, `plain`, or `plaintext` fences retain escaped plain code. There is no first-line language guessing. Mermaid and math fences continue through their existing renderers.

Grammars load once, on the first fence requiring language lookup. Each fence starts with fresh parsing state; multiline strings and comments carry state between its lines. Output preserves Unicode and literal HTML as code. Highlighting errors and panics discard partial output and return escaped source. Fences exceeding 256 KiB of UTF-8 source or 5,000 lines skip highlighting but display the complete source. These limits bound input size; they do not impose a regex execution timeout.

Token classes use the `syntax-` prefix. Attribute order is deterministic so regional parser guards can compare rendered HTML. Themes are generated ahead of time; theme loading and CSS generation do not run on document edits.

## Test documents and checks

The [fixture directory](../Tests/fixtures/highlighting/) contains:

- `languages.md`: twelve languages and representative tokens.
- `extended.md`: eight additional languages, including TSX markup and Typst code, markup, and math.
- `edge-cases.md`: multiline state, nested fences, extra fence metadata, HTML escaping, plain and extended grammars, Mermaid, and math.
- `stress.md`: one hundred independent multiline fences.
- `native.md`: native color, escaping, resize, edit, undo/redo, Mermaid, and math checks.

Rust tests exercise language dispatch, escaping, state isolation, CRLF/Unicode coordinates, input limits, and deterministic repeated output. Swift tests verify record-bridge coverage, exact code text, renderer coexistence, and regional edits against a fresh parse. The native integration check verifies DOM token classes, colored pixels, literal HTML, resize, and editing.

```sh
bash scripts/check-preview.sh
# Focused native check after building the debug app:
dist/debug/Markato.app/Contents/MacOS/Markato --integration-test --integration-highlighting
```

Regenerate the stylesheet after changing themes or Syntect:

```sh
cargo run --locked --manifest-path Native/Comrak/Cargo.toml --target-dir .build/comrak --example highlight_styles > Sources/HTMLPreview/Resources/CodeHighlight.css
```

See [benchmark measurements and reproduction](../benchmarks/highlighting/README.md). Dependency licenses ship in `SyntectAndDependencies.txt` and `TwoFace.txt`/`TwoFaceGrammars.txt` alongside the existing notices.

Regenerate the extended grammar acknowledgements with `highlight_styles --syntax-notices` (using the Cargo command above) and save its output as `App/Resources/ThirdPartyNotices/TwoFaceGrammars.txt`.
