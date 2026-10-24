import importlib.util, sys, glob, os
spec = importlib.util.spec_from_file_location('mkdrive', '/Users/scottmoschella/work/n-gage/tools/mkdrive.py')
mk = importlib.util.module_from_spec(spec); spec.loader.exec_module(mk)
def walk(n):
    if not n.is_dir: return len(n.data), 1
    s = c = 0
    for ch in n.children.values():
        a, b = walk(ch); s += a; c += b
    return s, c
rows = []
for z in sorted(glob.glob(sys.argv[1] + '/*.zip')):
    try:
        t = mk.card_root(mk.load_tree(z))
        s, c = walk(t)
        rows.append((s, os.path.basename(z)[:70], c))
    except Exception as e:
        rows.append((-1, os.path.basename(z)[:70] + ' ERR ' + str(e)[:40], 0))
for s, n, c in sorted(rows, reverse=True):
    if s > 28 << 20 or s < 0: print(f'{s/2**20:7.2f} MB  {c:5d} files  {n}')
print(len(rows), 'zips;', sum(1 for r in rows if r[0] > 30 << 20), 'over 30 MB of content')
