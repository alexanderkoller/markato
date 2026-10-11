#!/usr/bin/env python3
from __future__ import annotations

import json
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SIZES = (65536, 1048576, 8388608)
WINDOWS = (128, 256, 384, 512)
ROUNDS = 5


def main() -> None:
    binary = ROOT / "build/ultralight_window_bench"
    cwd = ROOT / "third_party/ultralight"
    stamp = time.strftime("%Y%m%d-%H%M%S")
    raw_path = ROOT / "raw" / f"ultralight-window-{stamp}.jsonl"
    records: list[dict[str, object]] = []
    with raw_path.open("w") as raw:
        for window in WINDOWS:
            for size in SIZES:
                fixture = ROOT / "fixtures" / f"prose-{size}.html"
                arguments = [binary, fixture, str(window), str(window // 8)]
                subprocess.run(arguments, cwd=cwd, check=True, capture_output=True, text=True)
                for round_number in range(1, ROUNDS + 1):
                    process = subprocess.run(
                        arguments, cwd=cwd, check=True,
                        capture_output=True, text=True, timeout=60,
                    )
                    result = json.loads(process.stdout.splitlines()[-1])
                    record = {"source_bytes": size, "round": round_number, **result}
                    records.append(record)
                    raw.write(json.dumps(record) + "\n")
                    raw.flush()
                    print(window, size, round_number, "ok", flush=True)

    numeric = sorted({
        key for record in records for key, value in record.items()
        if isinstance(value, (int, float)) and not isinstance(value, bool)
    })
    summary = []
    for window in WINDOWS:
        for size in SIZES:
            group = [
                record for record in records
                if record["source_bytes"] == size and record["window_blocks"] == window
            ]
            row: dict[str, object] = {
                "source_bytes": size, "window_blocks": window, "rounds": len(group)
            }
            for key in numeric:
                values = [float(record[key]) for record in group if key in record]
                if values:
                    row[key] = statistics.median(values)
                    row[key + "_min"] = min(values)
                    row[key + "_max"] = max(values)
            row["overlap_retained"] = all(bool(record["overlap_retained"]) for record in group)
            summary.append(row)
    output = ROOT / "ultralight-window-summary.json"
    output.write_text(json.dumps(summary, indent=2) + "\n")
    (ROOT / "latest-ultralight-window-run.txt").write_text(raw_path.name + "\n")
    print(output)


if __name__ == "__main__":
    main()
