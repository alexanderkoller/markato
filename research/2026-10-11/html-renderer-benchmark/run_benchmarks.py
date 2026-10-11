#!/usr/bin/env python3
from __future__ import annotations

import json
import resource
import statistics
import subprocess
import time
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FIX = ROOT / "fixtures"
RAW = ROOT / "raw"
RAW.mkdir(exist_ok=True)

ENGINES = {
    "webkit": ([str(ROOT / "build/webkit_bench")], ROOT, 120, None),
    "ultralight": ([str(ROOT / "build/ultralight_bench")], ROOT / "third_party/ultralight", 120, None),
    "litehtml": ([str(ROOT / "build/litehtml/bin/litehtml_bench")], ROOT, 60, None),
    "affineui": ([str(ROOT / "build/affineui_bench")], ROOT, 60, None),
    "sciter": ([str(ROOT / "build/sciter_bench")], ROOT, 120, None),
}

SIZES = [65536, 1048576, 8388608]
ROUNDS = {
    ("affineui", 1048576): 3,
    ("affineui", 8388608): 1,
    ("litehtml", 8388608): 1,
}

def memory_limit(limit: int | None):
    if limit is None:
        return None
    def set_limit():
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
    return set_limit

def invoke(engine: str, size: int, round_no: int, warmup: bool = False) -> dict:
    prefix, cwd, timeout, mem = ENGINES[engine]
    fixture = FIX / f"prose-{size}.html"
    started = time.time()
    try:
        p = subprocess.run(prefix + [str(fixture)], cwd=cwd, text=True,
                           capture_output=True, timeout=timeout,
                           preexec_fn=memory_limit(mem))
        status = "ok" if p.returncode == 0 else "failed"
        result = None
        for line in reversed(p.stdout.splitlines()):
            if line.startswith("{"):
                try: result = json.loads(line); break
                except json.JSONDecodeError: pass
        record = {"engine": engine, "source_bytes": size, "round": round_no,
                  "warmup": warmup, "status": status, "exit_code": p.returncode,
                  "wall_ms": (time.time()-started)*1000, "result": result,
                  "stdout": p.stdout, "stderr": p.stderr}
    except subprocess.TimeoutExpired as e:
        record = {"engine": engine, "source_bytes": size, "round": round_no,
                  "warmup": warmup, "status": "timeout", "timeout_seconds": timeout,
                  "wall_ms": (time.time()-started)*1000,
                  "stdout": e.stdout or "", "stderr": e.stderr or "", "result": None}
    return record

def main():
    selected = sys.argv[1:] or list(ENGINES)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = RAW / f"run-{stamp}.jsonl"
    records=[]
    with path.open("w") as out:
        for engine in selected:
            for size in SIZES:
                if engine == "litehtml" and size == 8388608:
                    rec={"engine":engine,"source_bytes":size,"round":1,"warmup":False,
                         "status":"not_run_resource_limit","result":None,
                         "reason":"1 MiB used 706 MB RSS; linear memory projection exceeds the 4 GiB safety ceiling"}
                    records.append(rec);out.write(json.dumps(rec)+"\n");out.flush();print(engine,size,1,rec["status"],flush=True)
                    continue
                if engine == "sciter" and size == 8388608:
                    rec={"engine":engine,"source_bytes":size,"round":1,"warmup":False,
                         "status":"not_run_resource_limit","result":None,
                         "reason":"1 MiB used 539 MB RSS; linear memory projection exceeds the 4 GiB safety ceiling"}
                    records.append(rec);out.write(json.dumps(rec)+"\n");out.flush();print(engine,size,1,rec["status"],flush=True)
                    continue
                count=ROUNDS.get((engine,size),5)
                # Skip an unrecorded warmup where the resource-limit observation is expected to fail.
                if count > 1:
                    invoke(engine,size,0,True)
                for n in range(1,count+1):
                    rec=invoke(engine,size,n)
                    records.append(rec); out.write(json.dumps(rec)+"\n"); out.flush()
                    print(engine,size,n,rec["status"],flush=True)
                    if rec["status"] != "ok": break

    summary=[]
    keys=set()
    for r in records:
        if r["status"]=="ok" and r["result"]:
            keys.update(k for k,v in r["result"].items() if isinstance(v,(int,float)) and not isinstance(v,bool))
    for engine in selected:
        for size in SIZES:
            group=[r for r in records if r["engine"]==engine and r["source_bytes"]==size]
            ok=[r["result"] for r in group if r["status"]=="ok" and r["result"]]
            row={"engine":engine,"source_bytes":size,"attempts":len(group),"completed":len(ok),
                 "status":"ok" if ok else (group[-1]["status"] if group else "missing")}
            for key in sorted(keys):
                vals=[x[key] for x in ok if key in x]
                if vals: row[key]=statistics.median(vals)
            summary.append(row)
    (ROOT/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
    (ROOT/"latest-run.txt").write_text(path.name+"\n")
    print(path)

if __name__=="__main__": main()
