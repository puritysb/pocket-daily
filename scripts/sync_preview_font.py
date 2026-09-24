#!/usr/bin/env python3
"""Import the pinned, existing font asset and its notices; no download/device I/O."""
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FIRMWARE = ROOT.parent / "pocket-daily-firmware"
FONT = "PocketSansWorld_12.cpfont"
EXPECTED = "a1a15a6e9cdccd114cbaf34adb29fce08ad67d3dcd52b7970a77ab89db9ee753"
FILES = {
    FONT: "assets/fonts/PocketWorld/" + FONT,
    "README.md": "assets/fonts/PocketWorld/README.md",
    "KR-SC-OFL.txt": "assets/fonts/PocketKR/OFL.txt",
    "JP-OFL.txt": "assets/fonts/PocketJP/OFL.txt",
    "NotoSans-OFL.txt": "lib/EpdFont/builtinFonts/source/NotoSans/OFL.txt",
    "Hebrew-OFL.txt": "lib/EpdFont/builtinFonts/source/NotoSansHebrew/OFL.txt",
}


def main():
    font = FIRMWARE / FILES[FONT]
    if font.stat().st_size != 10903872 or hashlib.sha256(font.read_bytes()).hexdigest() != EXPECTED:
        raise ValueError("The local font does not match the reviewed preview asset")
    destination = ROOT / "Support/PreviewFont"
    if destination.exists():
        raise ValueError("PreviewFont already exists; review an explicit font upgrade instead of overwriting it")
    staged = Path(tempfile.mkdtemp(prefix=".preview-font-", dir=ROOT / "Support"))
    for name, source in FILES.items():
        shutil.copyfile(FIRMWARE / source, staged / name)
    manifest = {"schema": 1, "font": FONT, "bytes": 10903872, "sha256": EXPECTED,
                "family": "PocketSansWorld", "pixels": 12,
                "notices": [name for name in FILES if name.endswith(".txt")]}
    (staged / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if hashlib.sha256((staged / FONT).read_bytes()).hexdigest() != EXPECTED:
        raise ValueError("Font changed during import")
    staged.rename(destination)
    print("Imported pinned preview font and source notices: " + str(destination))


if __name__ == "__main__":
    main()
