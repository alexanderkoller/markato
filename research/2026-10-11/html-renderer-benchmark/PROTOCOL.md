# Targeted HTML renderer benchmark

This benchmark measures the operations AstraMarkdown actually needs from an
embedded renderer. Markdown parsing and the application's document tree are
outside the timed region. Every engine receives the same complete HTML bytes,
CSS, 560 x 760 viewport, fixed system fonts, and no network resources.

For each 64 KiB, 1 MiB, and 8 MiB Markdown-derived fixture, a fresh process
reports:

1. engine and view construction;
2. HTML parse/style attachment;
3. layout needed to obtain a correct document height;
4. first clipped viewport paint or first rendered frame;
5. clipped paints at the top, middle, and end of the document;
6. a text mutation to the first visible block, followed by required layout and
   paint work;
7. peak and resident memory.

The harness verifies a positive, increasing document height and the locations
of the middle and end markers. A renderer without a supported incremental DOM
API is reported as such; replacing and reparsing the entire HTML string is not
presented as an in-place edit.

Builds use release optimization and one warm-up invocation. Reported values are
the median of five fresh-process observations, except where a run is explicitly
limited or stopped for time or memory. Raw JSON and every such exception are
retained.

The workload tests full-document mode: whether a renderer can keep a complete
DOM and make scrolling and edits cheap. The 64 KiB fixture also gives a useful
lower-size comparison, but it is not presented as a bounded-window result.

Chromium and Chromium-derived embedders are intentionally excluded.
