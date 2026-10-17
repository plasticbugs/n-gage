#!/usr/bin/env python3
"""Assemble an Analogue Pocket SD-card package from the compiled bitstream.

The Pocket loads a bit-reversed RBF (each byte's bits swapped) named per
core.json ("bitstream.rbf_r"). Output goes to release/pocket/ ready to copy
onto the SD card root.

Never ships a ROM: the copy step excludes them and there is a final sweep that
fails the package if one slipped through anyway.
"""
import os, shutil, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RBF = os.path.join(ROOT, "projects", "output_files", "mycore_pocket.rbf")
PKG = os.path.join(ROOT, "pkg", "pocket")
OUT = os.path.join(ROOT, "release", "pocket")
CORE_ID = "plasticbugs.mycore"

if not os.path.exists(RBF):
    sys.exit(f"missing {RBF} - run the Quartus compile first "
             "(and make sure the project generates a compressed RBF)")

REV = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
reversed_rbf = bytes(REV[b] for b in open(RBF, "rb").read())

if os.path.exists(OUT):
    shutil.rmtree(OUT)
# ROMs may sit in pkg/pocket/Assets locally (gitignored); never package them.
shutil.copytree(PKG, OUT, ignore=shutil.ignore_patterns('.DS_Store', '*.rom', '*.zip'))

core_dir = os.path.join(OUT, "Cores", CORE_ID)
with open(os.path.join(core_dir, "bitstream.rbf_r"), "wb") as f:
    f.write(reversed_rbf)

# Ship the ROM recipe and its builder alongside the core, so a downloaded
# release contains everything needed to produce mycore.rom.
for extra in ("mycore.mra", "README.md", os.path.join("tools", "mra_build.py")):
    src = os.path.join(ROOT, extra)
    if os.path.exists(src):
        shutil.copy(src, os.path.join(OUT, os.path.basename(extra)))

# Backstop: a gitignored test ROM in the package tree must never reach a release.
strays = [os.path.join(dp, f) for dp, _, fs in os.walk(OUT) for f in fs
          if f.lower().endswith(('.rom', '.zip'))]
if strays:
    sys.exit("refusing to package, ROM files present:\n  " + "\n  ".join(strays))

print(f"packaged -> {OUT}")
print("copy Cores/, Platforms/ and Assets/ from that folder onto the SD card root")
print("build the ROM with:  python3 mra_build.py mycore.mra mycore.zip")
