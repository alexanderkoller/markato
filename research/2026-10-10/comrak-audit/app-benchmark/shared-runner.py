#!/usr/bin/env python3
"""Run the shared probe in private, ad-hoc-signed snapshots of both release apps."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
WORK = Path('/private/tmp/astra-md3000-speed')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_sparse_fixture():
    fixtures = HERE / 'fixtures'
    paragraphs = ['# BENCH_START\n\n']
    total, i, headings = len(paragraphs[0]), 0, 0
    sentence = ('A paragraph with **bold**, *emphasis*, a [link](https://example.org), '
                'and `inline code`. This text supplies ordinary Markdown content '
                'for the editor and its rendered preview. ')
    while total < 1048576:
        heading = f'## Section {headings}\n\n' if i % 20 == 0 else ''
        headings += bool(heading)
        part = heading + f'Paragraph {i}. ' + sentence * 2 + '\n\n'
        paragraphs.append(part)
        total += len(part)
        i += 1
    file = fixtures / 'sparse-prose-1048576.md'
    file.write_text(''.join(paragraphs))
    entries = json.loads((HERE / 'fixtures.json').read_text())
    entries = [r for r in entries if r['fixture'] != file.name]
    entries.append({'fixture': file.name, 'bytes': file.stat().st_size,
                    'sha256': sha(file), 'sections': headings, 'paragraphs': i})
    (HERE / 'fixtures.json').write_text(json.dumps(entries, indent=2) + '\n')


def prepare():
    build = HERE / 'build'
    build.mkdir(exist_ok=True)
    subprocess.run(['xcrun', 'clang', '-O2', '-fobjc-arc', '-dynamiclib',
                    '-framework', 'AppKit', '-framework', 'WebKit',
                    str(HERE / 'probe.m'), '-o', str(build / 'probe.dylib')], check=True)
    fixtures = HERE / 'fixtures'
    fixtures.mkdir(exist_ok=True)
    (fixtures / 'warmup.md').write_text('# BENCH_WARMUP\n\nA short warmup paragraph.\n')
    block = ('## Section {i}\n\n'
             'A paragraph with **bold**, *emphasis*, a [link](https://example.org), '
             'and `inline code`. This text supplies ordinary Markdown content '
             'for the editor and its rendered preview.\n\n')
    metadata = []
    for size in [65536, 1048576, 4194304]:
        paragraphs = ['# BENCH_START\n\n']
        total, i = len(paragraphs[0]), 0
        while total < size:
            part = block.format(i=i)
            paragraphs.append(part)
            total += len(part)
            i += 1
        file = fixtures / f'prose-{size}.md'
        file.write_text(''.join(paragraphs))
        metadata.append({'fixture': file.name, 'bytes': file.stat().st_size,
                         'sha256': sha(file), 'sections': i})
    (HERE / 'fixtures.json').write_text(json.dumps(metadata, indent=2) + '\n')
    make_sparse_fixture()
    snapshots = {}
    suite_id = f'trial{time.time_ns()}'
    for label, original in [('ours', ROOT / 'dist/AstraMarkdown.app'),
                            ('macdown3000', WORK / 'mount/MacDown 3000.app')]:
        dest = WORK / f'{label}.app'
        if dest.exists():
            raise SystemExit(f'Snapshot already exists: {dest}; use --run-only to reuse it.')
        subprocess.run(['ditto', str(original), str(dest)], check=True)
        info_path = dest / 'Contents/Info.plist'
        with info_path.open('rb') as f:
            info = plistlib.load(f)
        executable = dest / 'Contents/MacOS' / info['CFBundleExecutable']
        original_executable = original / 'Contents/MacOS' / info['CFBundleExecutable']
        original_hash = sha(original_executable)
        bundle_id = f'org.astramarkdown.benchmark.{suite_id}.{label}'
        info['CFBundleIdentifier'] = bundle_id
        with info_path.open('wb') as f:
            plistlib.dump(info, f)
        # The private copies accept the observer library. Original bundles are untouched.
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(dest)], check=True)
        snapshots[label] = {'app': str(dest), 'executable': str(executable),
                            'bundleId': bundle_id, 'originalExecutableSHA256': original_hash,
                            'instrumentedExecutableSHA256': sha(executable),
                            'version': info.get('CFBundleShortVersionString', 'development'),
                            'resourceHashes': {str(f.relative_to(dest)): sha(f)
                                               for f in (dest / 'Contents/Resources').rglob('*')
                                               if f.is_file()}}
    (HERE / 'snapshots.json').write_text(json.dumps(snapshots, indent=2) + '\n')


def summarize(results):
    grouped = {}
    for result in results:
        if result['status'] != 'complete':
            continue
        for row in result['samples']:
            key = (result['fixture'], result['app'], row['operation'], result.get('runId', 'controlled'))
            grouped.setdefault(key, []).append(row['elapsedMs'])
    rows = []
    for (fixture, app, operation, experiment), values in sorted(grouped.items()):
        rows.append({'fixture': fixture, 'app': app, 'operation': operation,
                     'experiment': experiment, 'n': len(values), 'medianMs': statistics.median(values),
                     'minMs': min(values), 'maxMs': max(values)})
    (HERE / 'summary.json').write_text(json.dumps(rows, indent=2) + '\n')
    return rows


def run(rounds, sizes, run_id, start_round, edits, profile):
    snapshots = json.loads((HERE / 'snapshots.json').read_text())
    results = json.loads((HERE / 'runs.json').read_text()) if (HERE / 'runs.json').exists() else []
    raw = HERE / 'raw'
    raw.mkdir(exist_ok=True)
    for round_index in range(start_round - 1, start_round - 1 + rounds):
        labels = list(snapshots)
        for size in sizes:
            for label in labels:
                snapshot = snapshots[label]
                fixture = HERE / 'fixtures' / f'{profile}-{size}.md'
                expected = next(r['sha256'] for r in json.loads((HERE / 'fixtures.json').read_text())
                                if r['fixture'] == fixture.name)
                if sha(fixture) != expected:
                    raise SystemExit(f'Pristine fixture hash mismatch: {fixture}')
                private_input = WORK / 'inputs' / f'{label}-{size}-r{round_index + 1}-{run_id}.md'
                private_input.parent.mkdir(exist_ok=True)
                if private_input.exists():
                    raise SystemExit(f'Refusing to reuse input: {private_input}')
                shutil.copyfile(fixture, private_input)
                output = raw / f'{label}-{size}-r{round_index + 1}-{run_id}.jsonl'
                if output.exists():
                    raise SystemExit(f'Refusing to overwrite {output}')
                stderr = output.with_suffix('.stderr.txt')
                process_env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(HERE / 'build/probe.dylib'),
                                   BENCH_OUTPUT=str(output), BENCH_FIXTURE=str(private_input),
                                   BENCH_WARMUP=str(HERE / 'fixtures/warmup.md'),
                                   BENCH_APP_ID=snapshot['bundleId'], BENCH_EDITS=str(edits))
                started = time.time()
                print(f'RUN {label} {fixture.name} round={round_index + 1}', flush=True)
                with stderr.open('w') as log:
                    process = subprocess.Popen([snapshot['executable']], env=process_env,
                                               stdout=log, stderr=log)
                    try:
                        code = process.wait(timeout=150)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        try:
                            code = process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            code = process.wait()
                records = [json.loads(line) for line in output.read_text().splitlines()] if output.exists() else []
                complete = code == 0 and any(r['type'] == 'complete' for r in records)
                result = {'app': label, 'fixture': fixture.name, 'round': round_index + 1,
                          'runId': run_id, 'requestedEdits': edits,
                          'inputSHA256': expected, 'privateInputPath': str(private_input),
                          'pristineFixtureUnchanged': sha(fixture) == expected,
                          'startedUnix': started, 'wallSeconds': time.time() - started,
                          'exitCode': code, 'status': 'complete' if complete else 'failed',
                          'samples': [r for r in records if r['type'] == 'sample'],
                          'errors': [r for r in records if r['type'] == 'error']}
                results.append(result)
                (HERE / 'runs.json').write_text(json.dumps(results, indent=2) + '\n')
                rows = summarize(results)
                print(json.dumps(result), flush=True)
                if not complete:
                    raise SystemExit('Probe failed; inspect its stderr before continuing.')
                time.sleep(1)
    print(json.dumps(rows, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--run-only', action='store_true')
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--sizes', nargs='+', type=int, default=[65536, 1048576])
    parser.add_argument('--run-id', default='controlled')
    parser.add_argument('--start-round', type=int, default=1)
    parser.add_argument('--edits', type=int, default=7)
    parser.add_argument('--profile', choices=['prose', 'sparse-prose'], default='prose')
    args = parser.parse_args()
    if not args.run_only:
        prepare()
    if not args.prepare_only:
        run(args.rounds, args.sizes, args.run_id, args.start_round, args.edits, args.profile)
