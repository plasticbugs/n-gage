#!/usr/bin/env python3
"""Build a FAT16 volume (no partition table) from a directory or a zip.

    tools/mkdrive.py --from <dir|game.zip> --out drive.img [--size-mb N] [--label NAME]

This is the memory card the core's E: drive reads: the N-Gage's own FAT file
system (in EFile.exe, from the user's firmware) mounts it, so it has to be a
correct FAT volume, with VFAT long names (`6r29_caption.rsc` is not 8.3).
Files are laid out contiguously, in path order.  No dependencies.

A game zip as distributed holds the card's contents at its root
(`system/apps/...`); --from accepts the zip directly.

The boot sector's boot-code area, which FAT never reads, carries the launch
record the kernel reads (NGVM_LAUNCH_* in sw/include/ngvm_hw.h): the .app to
run, from the `Path:` line of the card's ngagegamestarter.txt, else the
card's only .app, else --app.
"""
import argparse, os, struct, sys, time, zipfile

SECTOR = 512


def lfn_checksum(short11):
    s = 0
    for c in short11:
        s = (((s & 1) << 7) | (s >> 1)) + c & 0xFF
    return s


class Node:
    def __init__(self, name, is_dir, data=b''):
        self.name, self.is_dir, self.data = name, is_dir, data
        self.children = {}
        self.cluster = 0


def short_names(names):
    """8.3 aliases in the style Windows makes: NAME~N.EXT when needed."""
    out, used = {}, set()
    for n in names:
        base, ext = (n.rsplit('.', 1) + [''])[:2] if '.' in n[1:] else (n, '')
        clean = lambda s: ''.join(c for c in s.upper() if c.isalnum() or c in '$%\'-_@~`!(){}^#&')
        b, e = clean(base), clean(ext)[:3]
        if n.upper() == n and len(b) <= 8 and len(ext) <= 3 and b == base.upper() and (b + e) and (b, e) not in used:
            cand = (b, e)
        else:
            i = 1
            while True:
                tail = '~%d' % i
                cand = (b[:8 - len(tail)] + tail, e)
                if cand not in used:
                    break
                i += 1
        used.add(cand)
        out[n] = cand[0].ljust(8).encode() + cand[1].ljust(3).encode()
    return out


def needs_lfn(name, short11):
    b, e = short11[:8].decode().rstrip(), short11[8:].decode().rstrip()
    return name != (b + ('.' + e if e else ''))


LAUNCH_OFF, LAUNCH_MAGIC, LAUNCH_MAX = 0x40, b'NGVMRUN\0', 0x1FE - 0x48


def find_app(tree):
    """The card's game, as E:\\... : what the N-Gage's game starter runs."""
    st = tree.children.get('ngagegamestarter.txt')
    if st:
        for line in st.data.decode('latin-1').splitlines():
            if line.lower().startswith('path:'):
                return 'E:' + line.split(':', 1)[1].strip()
    apps = []

    def walk(n, path):
        for c in n.children.values():
            p = path + '\\' + c.name
            if c.is_dir:
                walk(c, p)
            elif c.name.lower().endswith('.app'):
                apps.append('E:' + p)
    walk(tree, '')
    return apps[0] if len(apps) == 1 else None


def build(tree, size_mb, label, app=None):
    total = size_mb * 1024 * 1024 // SECTOR
    # pick the smallest cluster that keeps FAT16 within its cluster range
    for spc in (1, 2, 4, 8, 16, 32, 64):
        clusters = total // spc
        if clusters < 65525:
            break
    if clusters < 4085:
        sys.exit('volume too small for FAT16; use --size-mb 16 or more')
    reserved, nfats, root_entries = 1, 2, 512
    fat_sectors = ((clusters + 2) * 2 + SECTOR - 1) // SECTOR
    root_sectors = root_entries * 32 // SECTOR
    data_start = reserved + nfats * fat_sectors + root_sectors
    clusters = (total - data_start) // spc
    csize = spc * SECTOR
    fat = [0] * (clusters + 2)
    fat[0], fat[1] = 0xFFF8, 0xFFFF
    data = {}               # cluster -> bytes
    nxt = [2]

    def alloc(nbytes):
        n = max(1, (nbytes + csize - 1) // csize)
        first = nxt[0]
        if first + n > clusters + 2:
            sys.exit('drive full: raise --size-mb')
        for i in range(n):
            fat[first + i] = first + i + 1 if i < n - 1 else 0xFFFF
        nxt[0] += n
        return first

    stamp = time.gmtime(946684800)  # fixed date: images are reproducible
    fdate = ((stamp.tm_year - 1980) << 9) | (stamp.tm_mon << 5) | stamp.tm_mday
    ftime = 0

    def dirent(short11, attr, cluster, size):
        return struct.pack('<11sBBBHHHHHHHI', short11, attr, 0, 0, ftime, fdate, fdate, 0,
                           ftime, fdate, cluster, size)

    def entries_for(node, parent_cluster, self_cluster):
        out = []
        if self_cluster is not None:
            out.append(dirent(b'.          ', 0x10, self_cluster, 0))
            out.append(dirent(b'..         ', 0x10, parent_cluster, 0))
        names = sorted(node.children)
        shorts = short_names(names)
        for n in names:
            ch = node.children[n]
            s11 = shorts[n]
            if needs_lfn(n, s11):
                u = n.encode('utf-16le') + b'\0\0'
                u += b'\xff' * (-len(u) % 26)
                parts = [u[i:i + 26] for i in range(0, len(u), 26)]
                ck = lfn_checksum(s11)
                for k in range(len(parts), 0, -1):
                    p = parts[k - 1]
                    seq = k | (0x40 if k == len(parts) else 0)
                    out.append(struct.pack('<B10sBBB12sH4s', seq, p[0:10], 0x0F, 0, ck, p[10:22], 0, p[22:26]))
            out.append(dirent(s11, 0x10 if ch.is_dir else 0x20, ch.cluster, 0 if ch.is_dir else len(ch.data)))
        return b''.join(out)

    # allocate: directories first need their size, which needs their entries
    def place(node, parent_cluster, is_root):
        for n in sorted(node.children):
            ch = node.children[n]
            if ch.is_dir:
                est = len(entries_for(ch, 0, 0)) + 32
                ch.cluster = alloc(est)
            elif ch.data:
                ch.cluster = alloc(len(ch.data))
                data[ch.cluster] = ch.data
        for n in sorted(node.children):
            ch = node.children[n]
            if ch.is_dir:
                data[ch.cluster] = entries_for(ch, 0 if is_root else node.cluster, ch.cluster)
                place(ch, ch.cluster, False)
                data[ch.cluster] = entries_for(ch, 0 if is_root else node.cluster, ch.cluster)

    place(tree, 0, True)
    root = entries_for(tree, 0, None)
    vol = struct.pack('<11sB', label.upper().ljust(11)[:11].encode(), 0x08) + bytes(20)
    root = vol + root
    if len(root) > root_entries * 32:
        sys.exit('too many entries in the root directory')

    img = bytearray(total * SECTOR)
    bs = struct.pack('<3s8sHBHBHHBHHHII', b'\xEB\x3C\x90', b'NGVM1.0 ', SECTOR, spc, reserved, nfats,
                     root_entries, total if total < 65536 else 0, 0xF8, fat_sectors, 32, 64, 0,
                     total if total >= 65536 else 0)
    bs += struct.pack('<BBBI11s8s', 0x80, 0, 0x29, 0x4E474147, label.upper().ljust(11)[:11].encode(), b'FAT16   ')
    img[0:len(bs)] = bs
    if app:
        rec = LAUNCH_MAGIC + app.encode('ascii') + b'\0'
        if len(rec) > LAUNCH_MAX + 8:
            sys.exit('launch path too long')
        img[LAUNCH_OFF:LAUNCH_OFF + len(rec)] = rec
    img[510:512] = b'\x55\xAA'
    fatb = struct.pack('<%dH' % len(fat), *fat)
    for i in range(nfats):
        o = (reserved + i * fat_sectors) * SECTOR
        img[o:o + len(fatb)] = fatb
    o = (reserved + nfats * fat_sectors) * SECTOR
    img[o:o + len(root)] = root
    for c, b in data.items():
        o = (data_start + (c - 2) * spc) * SECTOR
        img[o:o + len(b)] = b
    used = (nxt[0] - 2) * csize
    return bytes(img), used


def load_tree(src):
    root = Node('', True)

    def add(path, data, is_dir):
        parts = [p for p in path.replace('\\', '/').split('/') if p and p != '.']
        n = root
        for i, p in enumerate(parts):
            last = i == len(parts) - 1
            if p not in n.children:
                n.children[p] = Node(p, is_dir or not last, data if last and not is_dir else b'')
            n = n.children[p]

    if zipfile.is_zipfile(src):
        with zipfile.ZipFile(src) as z:
            for info in z.infolist():
                add(info.filename, b'' if info.is_dir() else z.read(info), info.is_dir())
    else:
        for dp, dns, fns in os.walk(src):
            rel = os.path.relpath(dp, src)
            for d in dns:
                add(os.path.join(rel, d), b'', True)
            for f in fns:
                add(os.path.join(rel, f), open(os.path.join(dp, f), 'rb').read(), False)
    return root


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--from', dest='src', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--size-mb', type=int, default=0, help='default: the content plus 2 MB, at least 16')
    ap.add_argument('--label', default='NGAGE')
    ap.add_argument('--app', help='the .app to launch (E:\\...); default: from the card')
    a = ap.parse_args()
    tree = load_tree(a.src)
    content = 0

    def walk(n):
        nonlocal content
        for c in n.children.values():
            content += len(c.data)
            walk(c)
    walk(tree)
    size = a.size_mb or max(16, (content + 2 * 1024 * 1024 + 1048575) // 1048576 + 1)
    app = a.app or find_app(tree)
    img, used = build(tree, size, a.label, app)
    open(a.out, 'wb').write(img)
    print('%s: %d MB FAT16, %d bytes of files, %d bytes of clusters used; launches %s'
          % (a.out, size, content, used, app or 'nothing'))


if __name__ == '__main__':
    main()
