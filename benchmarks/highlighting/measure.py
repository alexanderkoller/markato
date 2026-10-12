#!/usr/bin/env python3
"""Collect warm samples and ten independently initialized parser processes."""
import csv
import io
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
binary = root / ".build/comrak/release/examples/highlight_benchmark"
destination = Path(__file__).resolve().parent
result = subprocess.run([str(binary), "101"], capture_output=True, text=True, check=True)
(destination / "results.csv").write_text(result.stdout)
rows = []
for run in range(1, 11):
    result = subprocess.run([str(binary), "1"], capture_output=True, text=True, check=True)
    row = next(csv.DictReader(io.StringIO(result.stdout)))
    rows.append({"run": run, **row})
with (destination / "cold.csv").open("w", newline="") as file:
    writer = csv.DictWriter(file, fieldnames=list(rows[0]), lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
