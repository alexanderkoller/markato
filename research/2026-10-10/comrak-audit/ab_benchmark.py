#!/usr/bin/env python3
"""Run two preserved app snapshots in alternating order under one protocol."""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import time

HERE = Path(__file__).resolve().parent
BENCH = HERE / "app-benchmark"
WORK = Path("/private/tmp/astra-comrak-port-benchmark")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("first")
    parser.add_argument("second")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--sizes", nargs="+", type=int, required=True)
    parser.add_argument("--profile", choices=["prose", "sparse-prose"], default="prose")
    parser.add_argument("--first-edit-delay-ms", type=int)
    args = parser.parse_args()

    snapshots_path = BENCH / "snapshots.json"
    saved_text = snapshots_path.read_text()
    all_snapshots = json.loads(saved_text)
    selected = {name: all_snapshots[name] for name in (args.first, args.second)}

    spec = importlib.util.spec_from_file_location("shared_runner", BENCH / "shared-runner.py")
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    runner.HERE = BENCH
    runner.WORK = WORK

    run_prefix = f"ab-{args.first}-vs-{args.second}-{time.time_ns()}"
    transcript = HERE / f"{run_prefix}.log"
    old_delay = os.environ.get("BENCH_FIRST_EDIT_DELAY_MS")
    if args.first_edit_delay_ms is not None:
        os.environ["BENCH_FIRST_EDIT_DELAY_MS"] = str(args.first_edit_delay_ms)
    try:
        with transcript.open("w") as output, contextlib.redirect_stdout(output):
            for round_index in range(args.rounds):
                order = (args.first, args.second) if round_index % 2 == 0 else (args.second, args.first)
                snapshots_path.write_text(json.dumps({name: selected[name] for name in order}))
                for size in args.sizes:
                    runner.run(1, [size], f"{run_prefix}-{args.profile}-pair{round_index + 1}",
                               round_index + 1, 3, args.profile)
                print(f"completed pair {round_index + 1}", flush=True)
    finally:
        snapshots_path.write_text(saved_text)
        if old_delay is None:
            os.environ.pop("BENCH_FIRST_EDIT_DELAY_MS", None)
        else:
            os.environ["BENCH_FIRST_EDIT_DELAY_MS"] = old_delay
    print(run_prefix)


if __name__ == "__main__":
    main()
