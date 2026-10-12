#!/usr/bin/env python3
"""Reproduce the MarkViewer v1.8.14 rows in docs/performance.md."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import statistics
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
EXPECTED_VERSION = "1.8.14"
EXPECTED_DMG_SHA256 = "2dd799c14dab4fb91f9f283f8e01630840b7ac601ef8baa5e9072f9cc497f722"
FIXTURE_SIZES = (65536, 1048576, 8388608)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def make_fixtures() -> dict[int, dict]:
    directory = HERE / "fixtures"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "warmup.md").write_text("# BENCH_WARMUP\n\nA short warmup paragraph.\n")
    block = (
        "## Section {i}\n\n"
        "A paragraph with **bold**, *emphasis*, a [link](https://example.org), "
        "and `inline code`. This text supplies ordinary Markdown content "
        "for the editor and its rendered preview.\n\n"
    )
    metadata = {}
    for requested_size in FIXTURE_SIZES:
        parts = ["# BENCH_START\n\n"]
        total = len(parts[0])
        section = 0
        while total < requested_size:
            part = block.format(i=section)
            parts.append(part)
            total += len(part)
            section += 1
        path = directory / f"prose-{requested_size}.md"
        path.write_text("".join(parts))
        metadata[requested_size] = {
            "path": str(path.relative_to(HERE)),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
            "sections": section,
        }
    (HERE / "fixtures.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def build_probe() -> Path:
    build = HERE / "build"
    build.mkdir(exist_ok=True)
    dylib = build / "markviewer-probe.dylib"
    subprocess.run([
        "xcrun", "clang", "-O2", "-fobjc-arc", "-dynamiclib",
        "-framework", "AppKit", "-framework", "WebKit",
        str(HERE / "probe.m"), "-o", str(dylib),
    ], check=True)
    return dylib


def verify_app(app: Path) -> Path:
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    version = info.get("CFBundleShortVersionString")
    if version != EXPECTED_VERSION:
        raise SystemExit(f"Expected MarkViewer {EXPECTED_VERSION}, found {version}")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if not executable.exists():
        raise SystemExit(f"Missing executable: {executable}")
    return executable


def summarize(runs: list[dict]) -> list[dict]:
    rows = []
    for requested_size in FIXTURE_SIZES:
        for operation in ("open", "edit"):
            values = [
                sample["elapsedMs"]
                for run in runs if run["requestedBytes"] == requested_size and run["status"] == "complete"
                for sample in run["samples"] if sample["operation"] == operation
            ]
            rows.append({
                "requestedBytes": requested_size,
                "operation": operation,
                "n": len(values),
                "medianMs": statistics.median(values) if values else None,
                "minMs": min(values) if values else None,
                "maxMs": max(values) if values else None,
            })
    (HERE / "summary.json").write_text(json.dumps(rows, indent=2) + "\n")
    return rows


def run(app: Path, rounds: int, edits: int) -> None:
    executable = verify_app(app)
    dylib = build_probe()
    fixtures = make_fixtures()
    raw = HERE / "raw"
    work = Path(tempfile.mkdtemp(prefix="markviewer-benchmark-", dir="/private/tmp"))
    inputs = work / "inputs"
    isolated_home = work / "preferences"
    for directory in (raw, inputs, isolated_home):
        directory.mkdir(parents=True, exist_ok=True)
    warmup = work / "warmup.md"
    shutil.copyfile(HERE / "fixtures" / "warmup.md", warmup)
    runs = []
    invocation = str(time.time_ns())
    timed_out_sizes = set()
    for round_index in range(1, rounds + 1):
        for requested_size in FIXTURE_SIZES:
            if requested_size in timed_out_sizes:
                continue
            pristine = HERE / fixtures[requested_size]["path"]
            copied = inputs / f"prose-{requested_size}-r{round_index}.md"
            shutil.copyfile(pristine, copied)
            output = raw / f"prose-{requested_size}-r{round_index}.jsonl"
            stderr = raw / f"prose-{requested_size}-r{round_index}.stderr.log"
            output.unlink(missing_ok=True)
            process_environment = dict(os.environ)
            process_environment.update({
                "DYLD_INSERT_LIBRARIES": str(dylib),
                "BENCH_OUTPUT": str(output),
                "BENCH_FIXTURE": str(copied),
                "BENCH_EDITS": str(edits),
                "CFFIXED_USER_HOME": str(isolated_home / invocation / f"r{round_index}-{requested_size}"),
                "HTTPS_PROXY": "http://127.0.0.1:9",
            })
            Path(process_environment["CFFIXED_USER_HOME"]).mkdir(parents=True, exist_ok=True)
            started = time.time()
            print(f"RUN MarkViewer {requested_size} bytes round={round_index}", flush=True)
            with stderr.open("w") as log:
                process = subprocess.Popen(
                    [str(executable), str(warmup)],
                    env=process_environment, stdout=log, stderr=log,
                )
                try:
                    # The in-process watchdog enforces 60 seconds per operation.
                    # This outer limit only catches a broken probe, so it must allow
                    # one warmup, one open, and every individually valid edit.
                    exit_code = process.wait(timeout=(edits + 2) * 65)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        exit_code = process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        exit_code = process.wait()
            records = [json.loads(line) for line in output.read_text().splitlines()] if output.exists() else []
            samples = [record for record in records if record.get("type") == "sample"]
            complete = exit_code == 0 and any(record.get("type") == "complete" for record in records)
            errors = [record for record in records if record.get("type") == "error"]
            timed_out = any("Timed out after 60 seconds" in record.get("message", "") for record in errors)
            run_record = {
                "application": "MarkViewer",
                "version": EXPECTED_VERSION,
                "requestedBytes": requested_size,
                "actualBytes": copied.stat().st_size,
                "fixtureSHA256": fixtures[requested_size]["sha256"],
                "round": round_index,
                "requestedEdits": edits,
                "status": "complete" if complete else ("timeout" if timed_out else "failed"),
                "exitCode": exit_code,
                "wallSeconds": time.time() - started,
                "samples": samples,
                "metadata": next((record for record in records if record.get("type") == "metadata"), None),
                "memory": next((record for record in records if record.get("type") == "memory"), None),
                "errors": errors,
                "pristineFixtureUnchanged": sha256(pristine) == fixtures[requested_size]["sha256"],
            }
            runs.append(run_record)
            (HERE / "results.json").write_text(json.dumps(runs, indent=2) + "\n")
            summarize(runs)
            edit_values = [sample["elapsedMs"] for sample in samples if sample["operation"] == "edit"]
            print(json.dumps({
                "size": requested_size,
                "round": round_index,
                "status": run_record["status"],
                "openMs": [sample["elapsedMs"] for sample in samples if sample["operation"] == "open"],
                "editMedianMs": statistics.median(edit_values) if edit_values else None,
            }), flush=True)
            if timed_out:
                timed_out_sizes.add(requested_size)
                continue
            if not complete:
                raise SystemExit(f"Probe failed; inspect {stderr}")
            time.sleep(1)
    print(json.dumps(summarize(runs), indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True, help="Private ad-hoc-signed MarkViewer.app copy")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--edits", type=int, default=3)
    arguments = parser.parse_args()
    run(arguments.app.resolve(), arguments.rounds, arguments.edits)
