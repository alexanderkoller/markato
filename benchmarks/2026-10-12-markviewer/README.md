# MarkViewer benchmark addition

This directory records the MarkViewer 1.8.14 measurements added to
`docs/performance.md`. The probe follows the existing application benchmark:
start a fresh process, render a warmup document, wait two seconds, open the
target through standard macOS document routing, and measure until the first H1
is both visible in MarkViewer's ProseMirror surface and present in a changed
WebKit frame. Across three fresh processes it records three opens and nine H1
edits, applying the same visible-frame endpoint to every edit.

The official DMG was 23,343,129 bytes with SHA-256
`2dd799c14dab4fb91f9f283f8e01630840b7ac601ef8baa5e9072f9cc497f722`.
The tested bundle reported version 1.8.14. The official signed app was copied,
the private copy was ad-hoc signed to permit the observer library, and the
official app itself was not modified. Private inputs live outside the repository
so MarkViewer does not mistake the fixture directory for a Git workspace. An
invalid loopback HTTPS proxy kept the automatic update check off the measured
network path.

The generated fixtures intentionally reproduce the historical corpus byte for
byte; their requested size is the display label, while `fixtures.json` records
the small block-boundary overshoot and exact hashes. `results.json` preserves
every accepted sample, `summary.json` contains the aggregate medians and
ranges, and `raw/` contains the probe records and application logs.

Run with a private, ad-hoc-signed app copy:

```sh
python3 benchmarks/2026-10-12-markviewer/run.py \
  --app /private/tmp/MarkViewer-benchmark.app
```

The probe automates MarkViewer in process; it does not use macOS Accessibility,
GUI scripting, or computer-use control.
