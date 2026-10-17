#!/usr/bin/env python3
"""Build every .mra with BOTH tools/mra_build.py and the standard `mra` tool
(mra-tools-c), and fail unless both give the md5 the .mra records.

    tools/check_mra.py <romdir> [file.mra ...]

<romdir> holds the MAME romsets as zips named as each .mra's zip attribute
(the way the standard tool finds them).  With no .mra named, every *.mra at
the top of the repo is checked.

Why: the people who build ROMs for the updaters use the standard tool, not
this repo's builder.  For years this template's builder read an interleave
`map` left to right while mra-tools-c reads it right to left, and the .mra
files matched the builder -- so the standard tool built a scrambled image from
every core that interleaves, with only an md5 warning (METHODOLOGY 5.7).  A
second thing only the standard tool enforces: an <interleave>'s parts must
supply every byte of the output word; it has no padding.

The standard tool: `git clone https://github.com/mist-devel/mra-tools-c &&
make -C mra-tools-c`, then put `mra` on PATH or set MRA_TOOL=/path/to/mra.
"""
import glob, hashlib, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))


def md5(path):
    return hashlib.md5(open(path, 'rb').read()).hexdigest() if os.path.exists(path) else None


def main(argv):
    if not argv:
        sys.exit(__doc__)
    romdir = os.path.abspath(argv[0])
    mras = [os.path.abspath(m) for m in argv[1:]] or sorted(glob.glob(os.path.join(ROOT, '*.mra')))
    tool = os.environ.get('MRA_TOOL') or shutil.which('mra')
    if not tool:
        sys.exit('the standard mra tool was not found: build mra-tools-c and put `mra` on PATH '
                 'or set MRA_TOOL (see this script\'s header)')
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        for mra in mras:
            text = open(mra).read()
            if '<part' not in re.sub(r'<!--.*?-->', '', text, flags=re.S):
                print(f'{os.path.basename(mra)}: no parts yet, skipped')
                continue
            want = (re.search(r'<rom[^>]*\bmd5="([^"]+)"', text) or [None, None])[1]
            wants = set(want.lower().split('|')) if want and want.lower() != 'none' else None
            zips = re.search(r'<rom[^>]*\bzip="([^"]+)"', text).group(1).split('|')
            src = next((os.path.join(romdir, z) for z in zips if os.path.exists(os.path.join(romdir, z))), None)
            if src is None:
                print(f'{os.path.basename(mra)}: none of {zips} in {romdir}, skipped')
                continue
            a, b = os.path.join(tmp, 'builder.rom'), os.path.join(tmp, 'mra.rom')
            for p in (a, b):
                if os.path.exists(p):
                    os.remove(p)
            r1 = subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'mra_build.py'), mra, src, a],
                                capture_output=True, text=True)
            r2 = subprocess.run([tool, '-z', romdir, '-o', b, mra], capture_output=True, text=True)
            m1, m2 = md5(a), md5(b)
            errs = [l for l in (r2.stdout + r2.stderr).splitlines() if 'error' in l.lower()]
            ok = m1 is not None and m1 == m2 and (wants is None or m1 in wants)
            bad += not ok
            print(f'{os.path.basename(mra)}: mra_build {m1}  mra {m2}  '
                  f'{"OK" if ok else "DIFFERENT"}'
                  + (f'  (.mra says {want})' if not ok and want else '')
                  + (f'  mra: {errs[0]}' if errs else '')
                  + ('' if m1 else f'  mra_build: {(r1.stdout + r1.stderr).strip().splitlines()[-1:]}'))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main(sys.argv[1:])
