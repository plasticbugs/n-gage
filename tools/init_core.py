#!/usr/bin/env python3
"""Stamp a new core's names through the template.  Run once, from the root.

    tools/init_core.py <shortname> "<Title>" [author]

    shortname   MAME's set name, lower case, no spaces: galaga, dkong, rastan.
                It becomes the module prefix, the Quartus project, the platform
                id, the Assets folder and the ROM image's name.
    Title       the game's name as people write it: "Dig Dug".
    author      the Cores/<author>.<shortname> prefix.  Default: plasticbugs.

Renames every file and directory with `mycore` in its name and rewrites
`mycore`, `MYCORE`, `My Core` and the author inside every text file.  It
refuses to run twice, and it never touches platform/, which is shared.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {'.git', 'platform', 'release', 'db', 'incremental_db', 'output_files', '__pycache__'}
BINARY = ('.bin', '.png', '.rbf', '.rbf_r', '.mif', '.wav', '.pyc')

def main():
    if len(sys.argv) < 3 or not re.fullmatch(r'[a-z][a-z0-9_]{1,15}', sys.argv[1]):
        sys.exit(__doc__)
    short, title = sys.argv[1], sys.argv[2]
    author = sys.argv[3] if len(sys.argv) > 3 else 'plasticbugs'
    if short == 'mycore':
        sys.exit('pick the real set name')
    if not os.path.exists(os.path.join(ROOT, 'rtl', 'mycore_core.sv')):
        sys.exit('rtl/mycore_core.sv is gone: this tree has already been initialised')

    def sub(t):
        return (t.replace('plasticbugs.mycore', f'{author}.{short}')
                 .replace('github.com/plasticbugs/', f'github.com/{author}/')
                 .replace('analogue-pocket-mycore', f'analogue-pocket-{short}')
                 .replace('My Core', title).replace('MY CORE', title.upper())
                 .replace('mycore', short).replace('MYCORE', short.upper()))

    changed = 0
    for dp, dns, fns in os.walk(ROOT, topdown=False):
        rel = os.path.relpath(dp, ROOT)
        if any(part in SKIP_DIRS for part in rel.split(os.sep)):
            continue
        for fn in fns:
            p = os.path.join(dp, fn)
            if os.path.abspath(p) == os.path.abspath(__file__):
                continue
            # METHODOLOGY and CREDITS name the cores a lesson was paid for on
            # and the people whose work this sits on.  Renaming those to the
            # new core would turn provenance into a false claim.
            if fn in ('METHODOLOGY.md', 'CREDITS.md'):
                continue
            if not fn.endswith(BINARY):
                try:
                    t = open(p).read()
                    n = sub(t)
                    if n != t:
                        open(p, 'w').write(n); changed += 1
                except (UnicodeDecodeError, IsADirectoryError):
                    pass
            if 'mycore' in fn:
                os.rename(p, os.path.join(dp, sub(fn)))
        for dn in dns:
            if 'mycore' in dn and dn not in SKIP_DIRS:
                os.rename(os.path.join(dp, dn), os.path.join(dp, sub(dn)))

    # The template's own front page and its notes become the core's: the core
    # gets the README stub, and the instructions for starting a core from the
    # template have no business travelling into one.
    src = os.path.join(ROOT, 'docs', 'core-README.md')
    if os.path.exists(src):
        os.replace(src, os.path.join(ROOT, 'README.md'))
    for gone in ('TEMPLATE.md',):
        q = os.path.join(ROOT, gone)
        if os.path.exists(q):
            os.remove(q)

    # the generic author string, where it stands alone
    if author != 'plasticbugs':
        for p in ('pkg/pocket/Cores/%s.%s/core.json' % (author, short), 'package-pocket.py'):
            q = os.path.join(ROOT, p)
            if os.path.exists(q):
                t = open(q).read(); open(q, 'w').write(t.replace('"plasticbugs"', f'"{author}"'))

    print(f'{changed} files rewritten for {author}.{short} ("{title}").')
    print('README.md is now the core\'s own; TEMPLATE.md is gone.')
    print('Next: tools/gen_qip.sh, then sim/lint.sh, then sim/run_mem.sh -quick.')
    print('Then fill in README.md and start docs/hardware.md from MAME\'s driver.')

if __name__ == '__main__':
    main()
