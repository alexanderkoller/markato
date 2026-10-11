#!/usr/bin/env python3
from __future__ import annotations

import json
import statistics
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SIZES = (65536, 1048576, 8388608)
RUN_FILES = (
    "run-20261011-072349.jsonl",  # WebKit, Ultralight
    "run-20261011-072430.jsonl",  # AffineUI (and superseded litehtml)
    "run-20261011-073007.jsonl",  # Sciter
    "run-20261011-073125.jsonl",  # corrected litehtml clip and marker validation
)


def derived(engine: str, result: dict) -> dict:
    r = dict(result)
    if engine in ("webkit", "ultralight", "sciter"):
        r["cold_first_view_ms"] = r.get("construct_ms", 0) + r["first_view_ms"]
    elif engine == "litehtml":
        r["cold_first_view_ms"] = r["parse_style_ms"] + r["layout_ms"] + r["paint_top_ms"]
    elif engine == "affineui":
        r["cold_first_view_ms"] = r["parse_style_ms"] + r["layout_ms"] + r["full_paint_ms"]

    if engine == "affineui":
        r["edit_to_view_ms"] = r["edit_mutation_ms"] + r["edit_layout_ms"] + r["edit_paint_ms"]
    elif "visible_edit_ms" in r:
        r["edit_to_view_ms"] = r["visible_edit_ms"]

    scroll = [r[k] for k in ("scroll_mid_ms", "scroll_end_ms") if k in r]
    if engine == "litehtml":
        scroll = [r[k] for k in ("paint_mid_ms", "paint_end_ms") if k in r]
    if scroll:
        r["deep_scroll_to_view_ms"] = max(scroll)
    return r


def main() -> None:
    groups = defaultdict(list)
    exceptions = defaultdict(list)
    inputs = [ROOT / "raw" / name for name in RUN_FILES]
    for path in inputs:
        for line in open(path):
            record = json.loads(line)
            if Path(path).name == "run-20261011-072430.jsonl" and record["engine"] == "litehtml":
                continue
            key = (record["engine"], record["source_bytes"])
            if record["status"] == "ok" and record.get("result"):
                groups[key].append(derived(record["engine"], record["result"]))
            else:
                exceptions[key].append({k: record[k] for k in
                    ("status", "reason", "timeout_seconds") if k in record})

    rows = []
    for engine in ("webkit", "ultralight", "sciter", "litehtml", "affineui"):
        for size in SIZES:
            values = groups[(engine, size)]
            row = {"engine": engine, "source_bytes": size, "n": len(values)}
            if values:
                numeric = sorted({k for v in values for k, x in v.items()
                                  if isinstance(x, (int, float)) and not isinstance(x, bool)})
                row["status"] = "ok"
                for key in numeric:
                    xs = [v[key] for v in values if key in v]
                    row[key] = {
                        "median": statistics.median(xs),
                        "min": min(xs),
                        "max": max(xs),
                    }
            else:
                row["status"] = exceptions[(engine, size)][-1]["status"] if exceptions[(engine, size)] else "missing"
            if exceptions[(engine, size)]:
                row["exceptions"] = exceptions[(engine, size)]
            rows.append(row)
    output = {"inputs": [p.name for p in inputs], "rows": rows}
    (ROOT / "summary.json").write_text(json.dumps(output, indent=2) + "\n")


if __name__ == "__main__":
    main()
