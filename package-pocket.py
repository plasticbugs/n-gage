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
RBF = os.path.join(ROOT, "projects", "output_files", "ngage_pocket.rbf")
PKG = os.path.join(ROOT, "pkg", "pocket")
OUT = os.path.join(ROOT, "release", "pocket")
CORE_ID = "plasticbugs.ngage"

if not os.path.exists(RBF):
    sys.exit(f"missing {RBF} - run the Quartus compile first "
             "(and make sure the project generates a compressed RBF)")

REV = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
reversed_rbf = bytes(REV[b] for b in open(RBF, "rb").read())

if os.path.exists(OUT):
    shutil.rmtree(OUT)
# ROMs may sit in pkg/pocket/Assets locally (gitignored); never package them.
shutil.copytree(PKG, OUT, ignore=shutil.ignore_patterns('.DS_Store', '*.rom', '*.zip', '*.img'))

core_dir = os.path.join(OUT, "Cores", CORE_ID)
with open(os.path.join(core_dir, "bitstream.rbf_r"), "wb") as f:
    f.write(reversed_rbf)

# The kernel is the core's own software and ships in its slot's folder;
# the drive builder ships beside the core, so a downloaded release has
# everything but the user's firmware and games.
KERNEL = os.path.join(ROOT, "build", "kernel", "kernel.bin")
if not os.path.exists(KERNEL):
    sys.exit(f"missing {KERNEL} - run make -C sw/kernel first")
shutil.copy(KERNEL, os.path.join(OUT, "Assets", "ngage", "common", "ngvm.bin"))
for extra in ("README.md", os.path.join("tools", "mkdrive.py")):
    src = os.path.join(ROOT, extra)
    if os.path.exists(src):
        shutil.copy(src, os.path.join(OUT, os.path.basename(extra)))

# Backstop: a gitignored test ROM in the package tree must never reach a release.
strays = [os.path.join(dp, f) for dp, _, fs in os.walk(OUT) for f in fs
          if f.lower().endswith(('.rom', '.zip', '.img'))]
if strays:
    sys.exit("refusing to package, ROM files present:\n  " + "\n  ".join(strays))

print(f"packaged -> {OUT}")
print("copy Cores/, Platforms/ and Assets/ from that folder onto the SD card root")
print("then add sym.rom and the games' .img files: Assets/ngage/common/README.txt")
