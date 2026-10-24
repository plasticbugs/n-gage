#!/usr/bin/env node
// tools/mkdrive.py's arguments and output, made by the engine inside the SD
// card's "Add N-Gage games.html" (pkg/pocket/Assets/ngage/common/), so the
// two can be compared: tools/check_mkdrive.py runs both on the same games.
//
//   node tools/mkdrive.mjs --from <dir|game.zip> --out drive.img [--size-mb N] [--label NAME] [--app E:\...]
//   node tools/mkdrive.mjs --md5 FILE        the page's MD5 of a file
//   --html PATH                               another copy of the page
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PAGE = path.join(HERE, '..', 'pkg', 'pocket', 'Assets', 'ngage', 'common', 'Add N-Gage games.html');

export function loadEngine(file = PAGE) {
    const s = fs.readFileSync(file, 'utf8');
    const a = s.indexOf('/*! engine'), b = s.indexOf('/*! end engine */');
    if (a < 0 || b < a) throw new Error('no engine in ' + file);
    return new Function(s.slice(a, b) + '\nreturn engine;')();
}

// a folder as os.walk gives it to load_tree: its directories and its files
function readDir(src) {
    const out = [];
    const walk = (dir, rel) => {
        for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
            const r = rel ? rel + '/' + e.name : e.name, p = path.join(dir, e.name);
            if (e.isDirectory()) { out.push({ path: r, isDir: true, data: new Uint8Array(0) }); walk(p, r); }
            else out.push({ path: r, isDir: false, data: new Uint8Array(fs.readFileSync(p)) });
        }
    };
    walk(src, '');
    return out;
}

async function main(argv) {
    const a = { label: 'NGAGE', sizeMb: 0, app: null, html: PAGE };
    for (let i = 0; i < argv.length; i++) {
        const k = argv[i], v = () => argv[++i];
        if (k === '--from') a.src = v(); else if (k === '--out') a.out = v();
        else if (k === '--size-mb') a.sizeMb = parseInt(v(), 10); else if (k === '--label') a.label = v();
        else if (k === '--app') a.app = v(); else if (k === '--md5') a.md5 = v(); else if (k === '--html') a.html = v();
        else throw new Error('unknown argument ' + k);
    }
    const engine = loadEngine(a.html);
    if (a.md5) { console.log(engine.md5(new Uint8Array(fs.readFileSync(a.md5)))); return 0; }
    try {
        let entries = [];
        if (fs.statSync(a.src).isDirectory()) entries = readDir(a.src);
        else {
            const b = new Uint8Array(fs.readFileSync(a.src));
            if (engine.isZip(b)) entries = await engine.readZip(b);
        }
        const tree = engine.cardRoot(engine.loadTree(entries));
        const r = engine.makeImage(tree, { sizeMb: a.sizeMb, label: a.label, app: a.app });
        fs.writeFileSync(a.out, r.img);
        console.log(`${a.out}: ${r.size} MB FAT16, ${r.content} bytes of files, ${r.used} bytes of clusters used; launches ${r.app || 'nothing'}`);
        return 0;
    } catch (e) {
        if (!(e instanceof engine.NgError)) throw e;
        console.error(e.message);
        return 1;
    }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
    main(process.argv.slice(2)).then(code => process.exit(code), e => { console.error(e.stack || e); process.exit(2); });
