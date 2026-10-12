#!/usr/bin/env python3
"""Package standard PNG icon representations without macOS IconServices."""

import argparse
from pathlib import Path
import struct
import tempfile


# PNG-backed ICNS elements, including the separate Retina representations.
REPRESENTATIONS = (
    ("icp4", "icon_16x16.png", 16),
    ("ic11", "icon_16x16@2x.png", 32),
    ("icp5", "icon_32x32.png", 32),
    ("ic12", "icon_32x32@2x.png", 64),
    ("ic07", "icon_128x128.png", 128),
    ("ic13", "icon_128x128@2x.png", 256),
    ("ic08", "icon_256x256.png", 256),
    ("ic14", "icon_256x256@2x.png", 512),
    ("ic09", "icon_512x512.png", 512),
    ("ic10", "icon_512x512@2x.png", 1024),
)


def package(iconset: Path, output: Path) -> None:
    chunks = []
    for kind, filename, size in REPRESENTATIONS:
        path = iconset / filename
        png = path.read_bytes()
        if (len(png) < 33 or png[:8] != b"\x89PNG\r\n\x1a\n"
                or png[8:16] != b"\x00\x00\x00\x0dIHDR"
                or struct.unpack(">II", png[16:24]) != (size, size)
                or png[24:26] != b"\x08\x06"):
            raise ValueError(f"Expected an {size}x{size} 8-bit RGBA PNG: {path}")
        chunks.append(struct.pack(">4sI", kind.encode("ascii"), len(png) + 8) + png)
    body = b"".join(chunks)
    icon = struct.pack(">4sI", b"icns", len(body) + 8) + body
    # A failed conversion must not corrupt the previous packaged icon.
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
        temporary.write(icon)
        temporary_path = Path(temporary.name)
    try:
        temporary_path.chmod(0o644)
        temporary_path.replace(output)
    finally:
        temporary_path.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("iconset", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    package(arguments.iconset, arguments.output)
