#!/usr/bin/env python3
"""Hold the SD card's "Add N-Gage games.html" to tools/mkdrive.py, byte for byte.

    tools/check_mkdrive.py [--games DIR] [--rom SYM.ROM] [--keep]

Builds a set of zips and folders made to be awkward (both compression
methods, a Mac's __MACOSX, a zip of the game's folder, VFAT names that need
~N aliases, cp437 and UTF-8 names, the Info-ZIP Unicode path field, Zip64
records, a comment, bytes before the zip, data descriptors, duplicate
names, several .apps with a hidden .aif, a root too full, a game larger
than the drive's 32 MB window, a game too big)
and runs tools/mkdrive.py and tools/mkdrive.mjs (the page's engine) on each:
the same exit, the same printed line, the same image.  --games adds every
zip in DIR, and each unpacked as a folder; --rom checks the page's MD5 of
the firmware against hashlib's.  Needs Python 3 and Node 18 or later.  --html checks another copy of the
page (each fault planted in one must be caught).
"""
import argparse, hashlib, os, random, shutil, struct, subprocess, sys, tempfile, zipfile, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = os.path.join(ROOT, 'tools', 'mkdrive.py')
JS = os.path.join(ROOT, 'tools', 'mkdrive.mjs')
rng = random.Random(1234)


def app_image(size, uid3=0x10005A2B):
    """An E32 .app image: UIDs, a header whose code size (word 25) and code
    offset (word 12) say how much of the file it needs."""
    h = [0] * 31
    h[0], h[1], h[2] = 0x10000079, 0x100039CE, uid3
    h[12], h[25] = 0x7C, max(0, size - 0x7C)
    d = struct.pack('<31I', *h)
    return d + bytes(rng.getrandbits(8) for _ in range(max(0, size - len(d))))


def aif(hidden, captions=0, icons=2):
    """An .aif store: UIDs, the root's offset, the caption and icon tables,
    then the capability (version 3, embeddability, new file, hidden, launch)."""
    root = 20 + 64
    body = bytes(64)
    r = bytes([captions << 1]) + bytes(6 * captions) + bytes([icons << 1]) + bytes(6 * icons)
    r += struct.pack('<5i', 3, 0, 0, hidden, 0) + b'\0'
    return struct.pack('<5I', 0x10000037, 0x10003A38, 0x10005A2B, 0, root) + body + r


def rawzip(path, entries, comment=b'', prefix=b'', zip64=False, descriptor=False):
    """A zip written by hand, for what zipfile will not write: names in
    cp437 without the UTF-8 flag, extra fields, Zip64 records, descriptors.
    entries: (name bytes, data, method, flags, extra bytes)."""
    out = bytearray(prefix)
    cen = bytearray()
    for name, data, method, flags, extra in entries:
        comp = data
        if method == 8:
            c = zlib.compressobj(9, zlib.DEFLATED, -15)
            comp = c.compress(data) + c.flush()
        crc = zlib.crc32(data)
        off = len(out) - len(prefix)
        fl = flags | (8 if descriptor else 0)
        lcrc, lcs, lus = (0, 0, 0) if descriptor else (crc, len(comp), len(data))
        out += struct.pack('<4s5H3L2H', b'PK\x03\x04', 20, fl, method, 0, 0x21, lcrc, lcs, lus, len(name), 0) + name
        out += comp
        if descriptor:
            out += struct.pack('<4s3L', b'PK\x07\x08', crc, len(comp), len(data))
        cs, us, ho, x = len(comp), len(data), off, extra
        if zip64:
            x = struct.pack('<HHQQQ', 1, 24, us, cs, ho) + extra
            cs = us = ho = 0xFFFFFFFF
        cen += struct.pack('<4s6H3L5H2L', b'PK\x01\x02', 20, 45 if zip64 else 20, fl, method, 0, 0x21,
                           crc, cs, us, len(name), len(x), 0, 0, 0, 0, ho) + name + x
    cd_off = len(out) - len(prefix)
    out += cen
    n = len(entries)
    if zip64:
        z64 = len(out) - len(prefix)
        out += struct.pack('<4sQ2H2L4Q', b'PK\x06\x06', 44, 45, 45, 0, 0, n, n, len(cen), cd_off)
        out += struct.pack('<4sLQL', b'PK\x06\x07', 0, z64, 1)
        out += struct.pack('<4s4H2LH', b'PK\x05\x06', 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, len(comment)) + comment
    else:
        out += struct.pack('<4s4H2LH', b'PK\x05\x06', 0, 0, n, n, len(cen), cd_off, len(comment)) + comment
    open(path, 'wb').write(out)


def files_game(app='VCop', extra=()):
    """A small game's card: an .app with its .aif, resources, a starter."""
    fs = {
        'system/apps/%s/%s.app' % (app, app): app_image(5000),
        'system/apps/%s/%s.aif' % (app, app): aif(0),
        'system/apps/%s/%s.rsc' % (app, app): os.urandom(700),
        'system/apps/%s/data/level01.dat' % app: os.urandom(3000),
        'system/apps/%s/data/6r29_caption.rsc' % app: os.urandom(90),
        'game.id': b'1234',
        'nokia.dat': b'',
    }
    fs.update(dict(extra))
    return fs


def write_zip(path, files, method=zipfile.ZIP_DEFLATED, dirs=False):
    with zipfile.ZipFile(path, 'w', method) as z:
        if dirs:
            seen = set()
            for n in sorted(files):
                parts = n.split('/')[:-1]
                for i in range(1, len(parts) + 1):
                    d = '/'.join(parts[:i]) + '/'
                    if d not in seen:
                        seen.add(d)
                        z.writestr(zipfile.ZipInfo(d), b'')
        for n, d in files.items():
            z.writestr(n, d)


def write_dir(path, files):
    for n, d in files.items():
        p = os.path.join(path, *n.split('/'))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'wb').write(d)


def cases(tmp):
    """(name, source path, extra arguments)"""
    out = []

    def z(name, files, **kw):
        p = os.path.join(tmp, name + '.zip')
        write_zip(p, files, **kw)
        out.append((name, p, []))
        return p

    starter = {'ngagegamestarter.txt': b'Name: Test\r\nPATH:  \\system\\apps\\VCop\\VCop.app \xa0\x1f\r\n'}
    z('deflated', files_game(extra=starter))
    z('stored', files_game(), method=zipfile.ZIP_STORED)
    z('with-dirs', files_game(), dirs=True)
    wrapped = {'Virtua Cop/' + k: v for k, v in files_game().items()}
    wrapped['__MACOSX/Virtua Cop/._game.id'] = b'\0\x05\x16\x07'
    z('wrapped', wrapped)
    z('wrapped-twice', {'a/b/' + k: v for k, v in files_game().items()})
    z('wrapped-junk', {**{'g/' + k: v for k, v in files_game().items()}, '.DS_Store': b'x', 'Thumbs.db': b'y'})
    z('not-unwrapped', {**{'a/' + k: v for k, v in files_game().items()}, 'b/readme.txt': b'hi'})
    z('no-system', {'readme.txt': b'not a game', 'data/x.bin': os.urandom(100)})
    names = {'system/apps/VCop/' + n: os.urandom(rng.randrange(0, 2000)) for n in [
        'longfilename%d.txt' % i for i in range(1, 13)] + [
        'readme.txt', 'README.TXT2', 'README.TX', 'a.html', 'a.b.c', '.hidden', 'x.', 'with space.dat',
        "$%'-_@~`!(){}^#&.x", 'exactly12chr', 'thirteen.char', 'AB~1.TXT', 'ab~1.txt', 'UPPER.DAT', 'MiXeD.Dat',
        'abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz.longext', 'empty.bin']}
    names['system/apps/VCop/empty.bin'] = b''
    names['system/apps/VCop/emptydir/'] = None
    z('names', {k: v for k, v in files_game(extra=names).items() if v is not None})
    z('utf8-names', files_game(extra={'system/apps/VCop/café.txt': b'x', 'system/apps/VCop/Ünïcode – dash.rsc': b'y'}))
    # several programs
    airplay = files_game('tomb', extra={
        'system/apps/tomb/stub.app': app_image(5000)[:900], 'system/apps/tomb/stub.aif': aif(0),
        'system/apps/gsbapp/gsbapp.app': app_image(3000), 'system/apps/tomb/tomb2.app': app_image(4000)})
    z('several-apps', airplay)
    z('snakes-like', {**files_game('6r45'), **{'system/apps/6r45_1/6r45_1.app': app_image(8000),
                                               'system/apps/6r45_1/6r45_1.aif': aif(1, captions=6)}})
    z('two-shown', {**files_game('aa'), **{'system/apps/bb/bb.app': app_image(8000), 'system/apps/bb/bb.aif': aif(0)}})
    z('starter-no-path', files_game(extra={'ngagegamestarter.txt': b'Name: x\n\x1cpath: \\system\\apps\\VCop\\VCop.app\n'}))
    big_root = {'f%03d.txt' % i: b'x' for i in range(600)}
    big_root['system/x'] = b'y'
    z('root-full', big_root)
    z('past-window', files_game(extra={'system/apps/VCop/huge.bin': os.urandom(33 * 1024 * 1024)}), method=zipfile.ZIP_STORED)
    z('too-big', files_game(extra={'system/apps/VCop/huge.bin': os.urandom(65 * 1024 * 1024)}), method=zipfile.ZIP_STORED)
    z('mid-size', files_game(extra={'system/apps/VCop/mid.bin': os.urandom(20 * 1024 * 1024)}), method=zipfile.ZIP_STORED)
    z('near-32mb', files_game(extra={'system/apps/VCop/big.bin': os.urandom(28 * 1024 * 1024)}), method=zipfile.ZIP_STORED)
    # written by hand
    g = files_game()
    ent = [(n.encode(), d, 8 if i % 2 else 0, 0, b'') for i, (n, d) in enumerate(g.items())]
    for name, kw in [('raw-plain', {}), ('raw-comment', {'comment': b'a comment'}),
                     ('raw-prefix', {'prefix': b'MZ' + os.urandom(3000)}), ('raw-zip64', {'zip64': True}),
                     ('raw-descriptor', {'descriptor': True}),
                     ('raw-zip64-comment-prefix', {'zip64': True, 'comment': b'c' * 300, 'prefix': os.urandom(77)})]:
        p = os.path.join(tmp, name + '.zip')
        rawzip(p, ent, **kw)
        out.append((name, p, []))
    cp = bytes(range(0x80, 0x100)).replace(b'/', b'').replace(b'\\', b'')
    raw_names = ent + [(b'system/apps/VCop/' + cp[:60] + b'.dat', b'cp437', 0, 0, b''),
                       (b'system/apps/VCop/' + cp[60:] + b'.dat', b'cp437b', 0, 0, b''),
                       ('system/apps/VCop/ütf8.txt'.encode(), b'u', 0, 0x800, b''),
                       (b'system/apps/VCop/nul\0hidden.txt', b'n', 0, 0, b''),
                       (b'system\\apps\\VCop\\back\\slash.txt', b'b', 0, 0, b''),
                       (b'system/apps/VCop/level01.dat', b'duplicate', 0, 0, b'')]
    uname = b'system/apps/VCop/old.txt'
    up = 'system/apps/VCop/nouveau é.txt'.encode()
    raw_names.append((uname, b'up', 0, 0, struct.pack('<HHBL', 0x7075, 5 + len(up), 1, zlib.crc32(uname)) + up))
    raw_names.append((b'system/apps/VCop/badcrc.txt', b'kept old', 0, 0, struct.pack('<HHBL', 0x7075, 5 + 3, 1, 1234) + b'new'))
    p = os.path.join(tmp, 'raw-names.zip')
    rawzip(p, raw_names)
    out.append(('raw-names', p, []))
    # a zip that is damaged: one byte of a deflated file changed
    p = os.path.join(tmp, 'damaged.zip')
    write_zip(p, files_game(), method=zipfile.ZIP_STORED)
    d = bytearray(open(p, 'rb').read())
    d[200] ^= 0xFF
    open(p, 'wb').write(d)
    out.append(('damaged', p, []))
    p = os.path.join(tmp, 'not-a-zip.bin')
    open(p, 'wb').write(os.urandom(5000))
    out.append(('not-a-zip', p, []))
    # folders
    for name, files in [('dir-game', files_game(extra=starter)), ('dir-wrapped', wrapped),
                        ('dir-names', {k: v for k, v in files_game(extra=names).items() if v is not None})]:
        p = os.path.join(tmp, name)
        write_dir(p, files)
        if name != 'dir-wrapped':
            os.makedirs(os.path.join(p, 'system', 'emptydir'), exist_ok=True)
        out.append((name, p, []))
    # the arguments
    src = os.path.join(tmp, 'deflated.zip')
    out += [('arg-size', src, ['--size-mb', '20']), ('arg-label', src, ['--label', 'Mmc Card']),
            ('arg-app', src, ['--app', 'E:\\system\\apps\\other\\other.app']), ('arg-small', src, ['--size-mb', '1']),
            ('arg-past-window', src, ['--size-mb', '33']), ('arg-over', src, ['--size-mb', '65'])]
    return out


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--games', help='a folder of game zips to add')
    ap.add_argument('--rom', help="the firmware, to check the page's MD5")
    ap.add_argument('--keep', action='store_true', help='keep the work folder')
    ap.add_argument('--html', help='another copy of the page (to check that a planted fault is caught)')
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix='check_mkdrive.')
    bad = 0
    try:
        todo = cases(tmp)
        if a.games:
            for f in sorted(os.listdir(a.games)):
                if f.lower().endswith('.zip'):
                    src = os.path.join(a.games, f)
                    todo.append(('game: ' + f, src, []))
                    d = os.path.join(tmp, 'unz-' + f[:-4])
                    zipfile.ZipFile(src).extractall(d)
                    todo.append(('game folder: ' + f, d, []))
        for name, src, extra in todo:
            o1, o2 = os.path.join(tmp, 'py.img'), os.path.join(tmp, 'js.img')
            for o in (o1, o2):
                if os.path.exists(o):
                    os.remove(o)
            r1 = run([sys.executable, PY, '--from', src, '--out', o1] + extra)
            r2 = run(['node', JS, '--from', src, '--out', o2] + extra + (['--html', a.html] if a.html else []))
            out1, out2 = r1[1].replace(o1, 'OUT'), r2[1].replace(o2, 'OUT')
            same = r1[0] == r2[0] and out1 == out2
            if r1[0] == 0 and same:
                same = open(o1, 'rb').read() == open(o2, 'rb').read()
            if r1[0] != 0 and r2[0] != 0:
                # both refused: mkdrive.py's own messages must match; an
                # exception from zipfile need only be refused
                msg1 = r1[2].splitlines()[-1] if r1[2] else ''
                same = msg1 == r2[2] or 'Traceback' in r1[2]
                what = 'refused: ' + (r2[2] or '?')
            else:
                what = out1.split('; ', 1)[-1] if r1[0] == 0 else r1[2]
            print('%-4s %-40s %s' % ('ok' if same else 'DIFF', name[:40], what[:90]))
            if not same:
                bad += 1
                print('       mkdrive.py:  exit %d  %s  %s' % (r1[0], out1, r1[2][-300:]))
                print('       mkdrive.mjs: exit %d  %s  %s' % (r2[0], out2, r2[2][-300:]))
        # the page's MD5
        for n in [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 1000003]:
            p = os.path.join(tmp, 'md5.bin')
            data = os.urandom(n)
            open(p, 'wb').write(data)
            got = run(['node', JS, '--md5', p] + (['--html', a.html] if a.html else []))[1]
            ok = got == hashlib.md5(data).hexdigest()
            bad += not ok
            if not ok:
                print('DIFF md5 of %d bytes: %s' % (n, got))
        print('ok   md5 of 13 lengths, 0 to 1,000,003 bytes' if not bad else '')
        if a.rom:
            got = run(['node', JS, '--md5', a.rom])[1]
            want = hashlib.md5(open(a.rom, 'rb').read()).hexdigest()
            print('%-4s md5 of %s: %s' % ('ok' if got == want else 'DIFF', os.path.basename(a.rom), got))
            bad += got != want
    finally:
        if a.keep:
            print('work folder:', tmp)
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print('%d cases differ' % bad if bad else 'the page and mkdrive.py agree')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
