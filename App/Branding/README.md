# Markato icon

`Markato-1024.png` is the approved transparent master: an ivory forward-leaning M and a coral open marcato wedge with the same lean, on an ink-blue rounded tile.

Generated with the built-in imagegen tool, then exported at 1024 × 1024 pixels. The production extraction prompt preserved the approved tile, lettering, wedge, internal shading, and colors, removed the gray presentation background and external shadow, and requested transparent margins. No API or image-generation service is required to build the app.

Run `bash scripts/build-icons.sh` from the repository root to regenerate the ten standard macOS PNG representations, the packaged `.icns`, and the README PNG. The app packaging script runs this automatically. Derived images are checked in for inspection and use outside the app build.

Resizing uses macOS `sips`; `scripts/package-icon.py` wraps the PNGs in the standard ICNS container using Python 3's standard library. It requires no additional Python packages or IconServices access. Unlike `iconutil`, it also works inside the build sandbox. The packager checks each representation's dimensions and RGBA format before replacing the `.icns` atomically.
