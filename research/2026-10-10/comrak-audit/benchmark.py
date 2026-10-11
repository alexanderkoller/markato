#!/usr/bin/env python3
"""Preserve app snapshots and compare identical open/edit operations.

Passing two labels runs a paired comparison with alternating process order.
Each process reports robust edit statistics and optional internal timing phases;
the probe records its polling interval and observed main-queue gaps so UI noise
is visible rather than being mistaken for parser time.
"""
import argparse
import hashlib
import importlib.util
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
BENCH = HERE / 'app-benchmark'
WORK = Path('/private/tmp/astra-comrak-port-benchmark')
LEGACY = ROOT / 'research/2026-10-06/macdown3000-benchmark'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def build_probe():
    build = BENCH / 'build'
    build.mkdir(exist_ok=True)
    subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-arch', 'x86_64', '-O2',
                    '-fobjc-arc', '-dynamiclib', '-framework', 'AppKit',
                    str(BENCH/'probe.m'), '-o', str(build/'probe.dylib')], check=True)

def prepare(label, original):
    BENCH.mkdir(exist_ok=True)
    WORK.mkdir(exist_ok=True)
    snapshots_path = BENCH / 'snapshots.json'
    snapshots = json.loads(snapshots_path.read_text()) if snapshots_path.exists() else {}
    if label in snapshots:
        raise SystemExit(f'Snapshot already exists: {label}')
    if not (BENCH / 'probe.m').exists():
        probe = (LEGACY / 'probe.m').read_text()
        probe = probe.replace('static NSDocument *document;', 'static NSDocument *document;\nstatic NSMutableArray<NSDocument *> *closedDocuments;')
        probe = probe.replace('        [document close];', '        if (!closedDocuments) closedDocuments = [NSMutableArray array];\n        [closedDocuments addObject:document];\n        [document close];')
        probe = probe.replace('                for (NSDocument *doc in', '                if (!closedDocuments) closedDocuments = [NSMutableArray array];\n                [closedDocuments addObjectsFromArray:[NSDocumentController sharedDocumentController].documents.copy];\n                for (NSDocument *doc in')
        probe = probe.replace('static void findViews(NSView *view) {', 'static void findViews(NSView *view) {\n    if (view.hidden) return;')
        probe = probe.replace('    // A short result and the same forced visible-element geometry read in both apps.', '    web = nil;\n    findViews(document.windowControllers.firstObject.window.contentView);\n    if (!web) { completion(@"", nil); return; }\n    // A short result and the same forced visible-element geometry read in both apps.')
        (BENCH / 'probe.m').write_text(probe)
        fixtures = BENCH / 'fixtures'
        fixtures.mkdir(exist_ok=True)
        for name in ['warmup.md','prose-65536.md','prose-1048576.md','sparse-prose-1048576.md']:
            shutil.copyfile(LEGACY/'fixtures'/name, fixtures/name)
        rows = json.loads((LEGACY/'fixtures.json').read_text())
        (BENCH/'fixtures.json').write_text(json.dumps(rows,indent=2)+'\n')
        runner = (LEGACY/'run.py').read_text().replace("labels = ['ours', 'macdown3000'] if round_index % 2 == 0 else ['macdown3000', 'ours']", 'labels = list(snapshots)')
        (BENCH/'shared-runner.py').write_text(runner)
    build_probe()
    dest = BENCH / 'snapshots' / f'{label}.app'
    dest.parent.mkdir(exist_ok=True)
    assert not dest.exists(), dest
    shutil.copytree(original, dest, symlinks=True)
    # The installed legacy bundle has duplicated framework aliases rather than
    # symlinks. Restore conventional aliases in this private copy for codesign;
    # the versioned executable/resources remain byte-identical.
    for framework in (dest/'Contents/Frameworks').glob('*.framework'):
        versions = framework/'Versions'
        if (versions/'A').is_dir():
            for name, target in [('Current','A')]:
                alias = versions/name
                if alias.exists() and not alias.is_symlink():
                    shutil.rmtree(alias)
                    alias.symlink_to(target)
            for name in ['Resources', framework.stem]:
                alias = framework/name
                if alias.exists() and not alias.is_symlink():
                    if alias.is_dir(): shutil.rmtree(alias)
                    else: alias.unlink()
                    alias.symlink_to('Versions/Current/'+name)
    for signature in dest.rglob('_CodeSignature'):
        if signature.is_file(): signature.unlink()
    info_path = dest/'Contents/Info.plist' 
    info = plistlib.loads(info_path.read_bytes())
    executable = dest/'Contents/MacOS'/info['CFBundleExecutable']
    original_hash = sha(executable)
    info['CFBundleIdentifier'] = f'org.astramarkdown.comrakbench.{time.time_ns()}.{label}'
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign','--force','--deep','--sign','-',str(dest)],check=True)
    snapshots[label] = {'app':str(dest), 'executable':str(executable), 'bundleId':info['CFBundleIdentifier'], 'originalExecutableSHA256':original_hash, 'instrumentedExecutableSHA256':sha(executable), 'version':info.get('CFBundleShortVersionString','development'), 'resourceHashes':{str(f.relative_to(dest)):sha(f) for f in (dest/'Contents/Resources').rglob('*') if f.is_file()}}
    snapshots_path.write_text(json.dumps(snapshots,indent=2)+'\n')

def percentile(values, fraction):
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = fraction * (len(ordered) - 1)
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)

def phase_summary(path):
    if not path or not Path(path).exists():
        return {}
    events = json.loads(Path(path).read_text()).get('events', [])
    names = {'parse.comrak', 'parse.viewport.work', 'html.presentation',
             'prepared.adopt', 'source.highlight', 'source.layout'}
    phases = {}
    for name in sorted(names):
        matching = [event for event in events if event.get('name') == name]
        values = [event['durationMs'] for event in matching]
        if values:
            phases[name] = {'n': len(values), 'medianMs': statistics.median(values),
                            'p90Ms': percentile(values, .9), 'totalMs': sum(values)}
            if name == 'parse.comrak':
                phases[name]['values'] = [event.get('values', {}) for event in matching]
    return phases

def report(run_prefix, labels):
    results = json.loads((BENCH/'runs.json').read_text())
    selected = [r for r in results if r.get('runId', '').startswith(run_prefix)
                and r.get('status') == 'complete']
    rows = []
    process_medians = {}
    for result in selected:
        values = [s['elapsedMs'] for s in result['samples'] if s['operation'] == 'edit']
        edit_samples = [s for s in result['samples'] if s['operation'] == 'edit']
        if not values:
            continue
        median = statistics.median(values)
        deviations = [abs(value - median) for value in values]
        key = (result['fixture'], result['app'])
        process_medians.setdefault(key, []).append(median)
        rows.append({'fixture': result['fixture'], 'app': result['app'],
                     'runId': result['runId'], 'n': len(values), 'medianMs': median,
                     'madMs': statistics.median(deviations),
                     'p10Ms': percentile(values, .1), 'p90Ms': percentile(values, .9),
                     'pollIntervalMs': (result.get('metadata') or {}).get('pollIntervalMs'),
                     'medianMaxPollGapMs': statistics.median(
                         sample.get('maxPollGapMs', 0) for sample in edit_samples),
                     'timingPhases': phase_summary(result.get('timingOutputPath'))})
    aggregates = []
    for (fixture, app), values in sorted(process_medians.items()):
        median = statistics.median(values)
        aggregates.append({'fixture': fixture, 'app': app, 'processes': len(values),
                           'medianOfProcessMediansMs': median,
                           'madOfProcessMediansMs': statistics.median(abs(v-median) for v in values),
                           'processMediansMs': values})
    pairs = []
    if len(labels) == 2:
        indexed = {(row['fixture'], row['runId'], row['app']): row['medianMs'] for row in rows}
        keys = sorted({(row['fixture'], row['runId']) for row in rows})
        for fixture in sorted({key[0] for key in keys}):
            differences = [indexed[(f, run_id, labels[1])] - indexed[(f, run_id, labels[0])]
                           for f, run_id in keys if f == fixture
                           and (f, run_id, labels[0]) in indexed
                           and (f, run_id, labels[1]) in indexed]
            if differences:
                pairs.append({'fixture': fixture, 'candidate': labels[1], 'baseline': labels[0],
                              'pairs': len(differences),
                              'medianPairedDifferenceMs': statistics.median(differences),
                              'pairedDifferencesMs': differences})
    result = {'runPrefix': run_prefix, 'perProcess': rows,
              'aggregates': aggregates, 'pairedComparisons': pairs}
    path = BENCH / f'{run_prefix}-comparison.json'
    path.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))

def run(labels, rounds, sizes=None, edits=9):
    build_probe()
    spec = importlib.util.spec_from_file_location('shared_runner', BENCH/'shared-runner.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.HERE = BENCH
    module.WORK = WORK
    # Restrict snapshot lookup without changing the timing or edit protocol.
    catalog = json.loads((BENCH/'snapshots.json').read_text())
    originals = {label: catalog[label] for label in labels}
    saved = (BENCH/'snapshots.json').read_text()
    run_prefix = f'{"-vs-".join(labels)}-{time.time_ns()}'
    os.environ['BENCH_QUIET_SUMMARY'] = '1'
    try:
        workloads = [('prose',65536),('prose',1048576),('sparse-prose',1048576)]
        if sizes is not None:
            workloads = [('prose', size) for size in sizes]
        for trial in range(rounds):
            for workload_index, (profile, size) in enumerate(workloads):
                offset = (trial + workload_index) % len(labels)
                order = labels[offset:] + labels[:offset]
                (BENCH/'snapshots.json').write_text(json.dumps({label: originals[label] for label in order}))
                run_id = f'{run_prefix}-{profile}-{size}-r{trial+1}'
                module.run(1,[size],run_id,1,edits,profile)
    finally:
        (BENCH/'snapshots.json').write_text(saved)
    report(run_prefix, labels)

if __name__ == '__main__':
    p=argparse.ArgumentParser()
    p.add_argument('labels', nargs='+', choices=['comrak-block-owned','comrak-regional-final','ultralight-bounded','baseline','comrak','comrak-final','comrak-retained','comrak-retained-tree','comrak-retained-final','comrak-retained-indexed','comrak-retained-local','comrak-visible-first','comrak-viewport','comrak-viewport-final','comrak-viewport-control','comrak-rope-overlap','comrak-rope-overlap-final','comrak-rope-overlap-idle','comrak-rope-overlap-clean','comrak-rope-overlap-narrow','comrak-rope-overlap-final-clean','comrak-rope-overlap-scoped','comrak-rope-serial-control','comrak-critical-path-clean','comrak-startup-clean','comrak-startup-final','comrak-startup-restored','comrak-startup-corrected','comrak-startup-parity','comrak-startup-debug','comrak-startup-verified','comrak-startup-stable','comrak-parity-ablation','comrak-clean-restored','comrak-inplace-fix','comrak-index-debug','comrak-index-debug2','comrak-gap-stable','comrak-gap-debug','comrak-concurrent-final','comrak-concurrent-complete','comrak-retained-concurrent-final','comrak-retained-debug','comrak-geometry-debug','comrak-structural-final','comrak-structural-final2','comrak-structural-debug','comrak-edit-window-debug','comrak-retained-window-final','comrak-retained-window-final2','comrak-cached-window','comrak-cached-window-editfix','comrak-complete-dom','comrak-complete-dom-editrestore','comrak-complete-dom-editrestore2','comrak-complete-dom-inplace','comrak-complete-dom-delta','comrak-complete-dom-delta2','comrak-complete-dom-delta3','comrak-complete-dom-delta4','comrak-complete-dom-delta-debug','comrak-complete-dom-delta5','comrak-complete-dom-delta-debug2','comrak-complete-dom-delta6','comrak-complete-dom-delta7','comrak-complete-dom-delta8','macdown073','macdown3000'])
    p._actions[-1].choices.append('current-block-owned')
    p.add_argument('--snapshot', type=Path)
    p.add_argument('--rounds', type=int, default=5)
    p.add_argument('--edits', type=int, default=9)
    p.add_argument('--sizes', nargs='+', type=int,
                   help='run only these dense-prose fixture sizes')
    p.add_argument('--prepare-only', action='store_true')
    p.add_argument('--first-edit-delay-ms', type=int)
    p.add_argument('--edit-delay-ms', type=int, default=250)
    p.add_argument('--poll-interval-us', type=int, default=1000)
    p.add_argument('--timing-directory', type=Path)
    args=p.parse_args()
    if args.snapshot:
        if len(args.labels) != 1:
            p.error('--snapshot requires exactly one label')
        prepare(args.labels[0],args.snapshot)
    if not args.prepare_only:
        if args.first_edit_delay_ms is not None:
            os.environ['BENCH_FIRST_EDIT_DELAY_MS']=str(args.first_edit_delay_ms)
        os.environ['BENCH_EDIT_DELAY_MS']=str(args.edit_delay_ms)
        os.environ['BENCH_POLL_INTERVAL_US']=str(args.poll_interval_us)
        if args.timing_directory is not None:
            os.environ['BENCH_TIMING_DIRECTORY']=str(args.timing_directory)
        run(args.labels,args.rounds,args.sizes,args.edits)
