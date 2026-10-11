#!/usr/bin/env python3
"""Build renderer fixtures from the existing deterministic Markdown corpus.

Markdown conversion is deliberately outside renderer timings.  The corpus uses
one heading followed by ordinary paragraphs, so this converter is intentionally
narrow and fails if it encounters syntax outside that contract.
"""

from __future__ import annotations

import hashlib
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent.parent / "2026-10-10/comrak-audit/app-benchmark/fixtures"
OUT = ROOT / "fixtures"

CSS = """
html,body { margin:0; padding:0; background:#fff; color:#202124; }
body { font:14px -apple-system,BlinkMacSystemFont,sans-serif; }
#preview { padding:16px; }
section { margin:0 0 12px; overflow-wrap:anywhere; }
p { margin:0 0 .65em; line-height:1.5; }
h1,h2 { margin:0 0 .5em; line-height:1.2; font-weight:700; }
h1 { font-size:24px; } h2 { font-size:20px; }
a { color:#1467c7; }
code { font-family:ui-monospace,Menlo,monospace; font-size:13px; background:#f1f1f1; }
""".strip()

INLINE = re.compile(r"\*\*(.+?)\*\*|\*(.+?)\*|\[([^]]+)\]\(([^)]+)\)|`([^`]+)`")


def inline(text: str) -> str:
    out: list[str] = []
    pos = 0
    for match in INLINE.finditer(text):
        out.append(html.escape(text[pos:match.start()]))
        strong, emphasis, label, href, code = match.groups()
        if strong is not None:
            out.append(f"<strong>{html.escape(strong)}</strong>")
        elif emphasis is not None:
            out.append(f"<em>{html.escape(emphasis)}</em>")
        elif label is not None:
            out.append(f'<a href="{html.escape(href, quote=True)}">{html.escape(label)}</a>')
        else:
            out.append(f"<code>{html.escape(code)}</code>")
        pos = match.end()
    out.append(html.escape(text[pos:]))
    return "".join(out)


def convert(source: Path, target: Path) -> dict[str, object]:
    lines = source.read_text().splitlines()
    blocks: list[tuple[str, str]] = []
    for line in lines:
        if not line:
            continue
        if line.startswith("## "):
            blocks.append(("h2", line[3:]))
        elif line.startswith("# "):
            blocks.append(("h1", line[2:]))
        elif line.startswith((" ", "#", ">", "- ", "* ", "+ ")):
            raise ValueError(f"unsupported fixture line: {line[:80]!r}")
        else:
            blocks.append(("p", line))

    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("w") as f:
        f.write("<!doctype html><html><head><meta charset=utf-8><style>")
        f.write(CSS)
        f.write("</style></head><body><main id=preview>")
        last = len(blocks) - 1
        for i, (tag, text) in enumerate(blocks):
            landmarks = []
            if i == 0:
                landmarks.append("edit-target")
            if i == len(blocks) // 2:
                landmarks.append("mid-target")
            if i == last:
                landmarks.append("end-target")
            ids = f' id="{" ".join(landmarks)}"' if landmarks else ""
            f.write(f'<section data-block="{i}"><{tag}{ids} class="block">{inline(text)}</{tag}></section>')
        f.write("</main></body></html>")

    data = target.read_bytes()
    return {
        "source": source.name,
        "source_bytes": source.stat().st_size,
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "html": target.name,
        "html_bytes": len(data),
        "html_sha256": hashlib.sha256(data).hexdigest(),
        "blocks": len(blocks),
    }


def main() -> None:
    manifest = []
    for size in (65536, 1048576, 8388608):
        manifest.append(convert(SOURCE / f"prose-{size}.md", OUT / f"prose-{size}.html"))
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
