# Markato stateless-interface benchmark

This directory preserves the end-to-end rerun made after removing retained
Rust parser state and eager interface copies. It uses the same in-process probe,
fixture bytes, 1120 by 760 point window, warmup, and visible-frame endpoint as
the comparison in `docs/performance.md`.

The probe launched three fresh release-build processes per fixture. Each process
recorded one open and nine edits to the first H1. An open completed when the
preview first visibly painted; an edit completed when the source contained its
unique marker and the preview frame changed. Polling used a 1 ms interval and
each operation had a 60-second limit.

| Fixture | Open median (3) | Edit median (27) | Open range | Edit range |
|---|---:|---:|---:|---:|
| 64 KB | 55.8 ms | 14.6 ms | 46.5–67.2 ms | 6.1–33.2 ms |
| 1 MB | 74.3 ms | 11.9 ms | 59.8–79.2 ms | 5.5–31.3 ms |
| 8 MB | 256.3 ms | 7.0 ms | 249.4–279.7 ms | 6.3–23.8 ms |

All nine processes completed, every edit marker was present in the source, and
the pristine fixture hashes still matched after the run. The release executable
inside the private benchmark copy had SHA-256
`14955fc267a9252c1071c283690b53be1338710ef7d8639ed67f80d2243abb89`.

`probe.m` is the in-process observer and driver. `results.json` contains the
full structured process records, `summary.json` contains the six aggregates,
`fixtures.json` records fixture sizes and hashes, and `raw/` contains the probe
output and application logs.
