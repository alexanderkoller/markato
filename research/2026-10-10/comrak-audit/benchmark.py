#!/usr/bin/env python3
"""Preserve app snapshots and compare identical open/edit operations."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BENCH = HERE / 'app-benchmark'
WORK = Path('/private/tmp/astra-comrak-port-benchmark')
LEGACY = ROOT / 'research/2026-10-06/macdown3000-benchmark'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(label, original):
    BENCH.mkdir(exist_ok=True)
    WORK.mkdir(exist_ok=True)
    snapshots_path = BENCH / 'snapshots.json'
    snapshots = json.loads(snapshots_path.read_text()) if snapshots_path.exists() else {}
    if label in snapshots:
        raise SystemExit(f'Snapshot already exists: {label}')
    build = BENCH / 'build'
    build.mkdir(exist_ok=True)
    if not (BENCH / 'probe.m').exists():
        probe = (LEGACY / 'probe.m').read_text()
        probe = probe.replace('static NSDocument *document;', 'static NSDocument *document;\nstatic NSMutableArray<NSDocument *> *closedDocuments;')
        probe = probe.replace('        [document close];', '        if (!closedDocuments) closedDocuments = [NSMutableArray array];\n        [closedDocuments addObject:document];\n        [document close];')
        probe = probe.replace('                for (NSDocument *doc in', '                if (!closedDocuments) closedDocuments = [NSMutableArray array];\n                [closedDocuments addObjectsFromArray:[NSDocumentController sharedDocumentController].documents.copy];\n                for (NSDocument *doc in')
        probe = probe.replace('static void findViews(NSView *view) {', 'static void findViews(NSView *view) {\n    if (view.hidden) return;')
        probe = probe.replace('    // A short result and the same forced visible-element geometry read in both apps.', '    web = nil;\n    findViews(document.windowControllers.firstObject.window.contentView);\n    if (!web) { completion(@"", nil); return; }\n    // A short result and the same forced visible-element geometry read in both apps.')
        (BENCH / 'probe.m').write_text(probe)
        subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-arch', 'x86_64', '-O2', '-fobjc-arc', '-dynamiclib', '-framework', 'AppKit', '-framework', 'WebKit', str(BENCH/'probe.m'), '-o', str(build/'probe.dylib')], check=True)
        fixtures = BENCH / 'fixtures'
        fixtures.mkdir(exist_ok=True)
        for name in ['warmup.md','prose-65536.md','prose-1048576.md','sparse-prose-1048576.md']:
            shutil.copyfile(LEGACY/'fixtures'/name, fixtures/name)
        rows = json.loads((LEGACY/'fixtures.json').read_text())
        (BENCH/'fixtures.json').write_text(json.dumps(rows,indent=2)+'\n')
        runner = (LEGACY/'run.py').read_text().replace("labels = ['ours', 'macdown3000'] if round_index % 2 == 0 else ['macdown3000', 'ours']", 'labels = list(snapshots)')
        (BENCH/'shared-runner.py').write_text(runner)
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

def run(label, rounds, sizes=None):
    spec = importlib.util.spec_from_file_location('shared_runner', BENCH/'shared-runner.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.HERE = BENCH
    module.WORK = WORK
    # Restrict snapshot lookup without changing the timing or edit protocol.
    original = json.loads((BENCH/'snapshots.json').read_text())[label]
    saved = (BENCH/'snapshots.json').read_text()
    (BENCH/'snapshots.json').write_text(json.dumps({label:original}))
    try:
        # One fresh-process observation per invocation, with unique inputs.
        run_prefix = f'{label}-{time.time_ns()}'
        workloads = [('prose',65536),('prose',1048576),('sparse-prose',1048576)]
        if sizes is not None:
            workloads = [('prose', size) for size in sizes]
        for trial in range(rounds):
            for profile, size in workloads:
                module.run(1,[size],f'{run_prefix}-{profile}-r{trial+1}',1,3,profile)
    finally:
        (BENCH/'snapshots.json').write_text(saved)

if __name__ == '__main__':
    p=argparse.ArgumentParser()
    p.add_argument('label', choices=['baseline','comrak','comrak-final','comrak-retained','comrak-retained-tree','comrak-retained-final','comrak-retained-indexed','comrak-retained-local','comrak-visible-first','comrak-viewport','comrak-viewport-final','comrak-viewport-control','comrak-rope-overlap','comrak-rope-overlap-final','comrak-rope-overlap-idle','comrak-rope-overlap-clean','comrak-rope-overlap-narrow','comrak-rope-overlap-final-clean','comrak-rope-overlap-scoped','comrak-rope-serial-control','comrak-critical-path-clean','comrak-startup-clean','comrak-startup-final','comrak-startup-restored','comrak-startup-corrected','comrak-startup-parity','comrak-startup-debug','comrak-startup-verified','comrak-startup-stable','comrak-parity-ablation','comrak-clean-restored','comrak-inplace-fix','comrak-index-debug','comrak-index-debug2','comrak-gap-stable','comrak-gap-debug','comrak-concurrent-final','comrak-concurrent-complete','comrak-retained-concurrent-final','comrak-retained-debug','comrak-geometry-debug','comrak-structural-final','comrak-structural-final2','comrak-structural-debug','comrak-edit-window-debug','comrak-retained-window-final','comrak-retained-window-final2','macdown073','macdown3000'])
    p.add_argument('--snapshot', type=Path)
    p.add_argument('--rounds', type=int, default=1)
    p.add_argument('--sizes', nargs='+', type=int,
                   help='run only these dense-prose fixture sizes')
    p.add_argument('--prepare-only', action='store_true')
    p.add_argument('--first-edit-delay-ms', type=int)
    p.add_argument('--timing-output', type=Path)
    args=p.parse_args()
    if args.snapshot: prepare(args.label,args.snapshot)
    if not args.prepare_only:
        if args.first_edit_delay_ms is not None:
            os.environ['BENCH_FIRST_EDIT_DELAY_MS']=str(args.first_edit_delay_ms)
        if args.timing_output is not None:
            os.environ['BENCH_TIMING_OUTPUT']=str(args.timing_output)
        run(args.label,args.rounds,args.sizes)
