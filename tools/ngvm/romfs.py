"""The firmware image's file system, read on the host: the EKA1 ROM header,
the directory tree, and each image's TRomImageHeader.  The same layouts as
sw/kernel/rom.c reads on the target."""
import struct

IMG_FIELDS = ['uid1', 'uid2', 'uid3', 'uidck', 'entry', 'code', 'data', 'codesize', 'textsize', 'datasize',
              'bss', 'heapmin', 'heapmax', 'stack', 'dllref', 'expcount', 'expdir', 'ckcode', 'ckdata',
              'ver', 'flags', 'prio', 'databss', 'nextext', 'hwvar']
EXEC_EXT = ('.exe', '.dll', '.app', '.ldd', '.pdd', '.fsy', '.fxt', '.csy', '.prt', '.tsy', '.fep', '.mdl',
            '.ctl', '.agt', '.drv', '.dsy', '.mtm', '.prn', '.rdl', '.opx', '.wsy', '.esy', '.nif', '.agt', '.tsy')


class RomFs:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        self.base = self.u32(0x8C)

    def u32(self, off):
        return struct.unpack_from('<I', self.d, off)[0]

    def w(self, addr):
        return self.u32(addr - self.base)

    def read(self, addr, n):
        o = addr - self.base
        return self.d[o:o + n]

    def _dir(self, addr, path):
        o = addr - self.base
        size = self.u32(o)
        p, end = o + 4, o + 4 + size
        while p < end:
            esize, eaddr, att, nl = struct.unpack_from('<IIBB', self.d, p)
            name = self.d[p + 10:p + 10 + 2 * nl].decode('utf-16le')
            full = path + '\\' + name
            yield full, eaddr, esize, att
            if att & 0x10:
                yield from self._dir(eaddr, full)
            p = (p + 10 + 2 * nl + 3) & ~3

    def files(self):
        lst = self.w(self.base + 0x94)
        for i in range(self.w(lst)):
            hw, addr = struct.unpack_from('<II', self.d, lst - self.base + 4 + 8 * i)
            yield from self._dir(addr, '')

    def image(self, addr):
        return dict(zip(IMG_FIELDS, struct.unpack_from('<25I', self.d, addr - self.base)))

    def images(self):
        seen = set()
        for path, addr, size, att in self.files():
            if att & 0x10 or not path.lower().endswith(EXEC_EXT) or addr in seen:
                continue
            seen.add(addr)
            img = self.image(addr)
            if img['code'] != addr + 0x64 and img['code'] != addr + 0x64 - 1:
                continue    # not an executable image (or not one we understand)
            yield path, img

    def exports(self, img):
        n = img['expcount']
        if not n or n > 5000:
            return []
        return list(struct.unpack_from('<%dI' % n, self.d, img['expdir'] - self.base))

    def find(self, path):
        want = path.lower().lstrip('z:')
        for p, addr, size, att in self.files():
            if p.lower() == want:
                return addr
        return None
