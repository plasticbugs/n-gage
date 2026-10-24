#!/usr/bin/env node
// Drives the SD card's "Add N-Gage games.html" in headless Chrome as a person
// would, and holds what it writes to tools/mkdrive.py:
//
//   node tools/check_mkdrive_page.mjs --games DIR [--rom SYM.ROM] [--chrome PATH] [--html PAGE]
//
// The SD card is a folder in the browser's private file system (OPFS), handed
// to the page in place of the folder picker, so the page writes through the
// same File System Access calls it makes on a real card.  Each game zip in
// DIR goes in through the page's file chooser in one batch; every image the
// page writes must be the bytes mkdrive.py makes of that zip, and every menu
// entry the JSON the core ships (or, for a card without saves, without slot 4).
// It also checks: a game dropped twice, renaming, a file that is not a game,
// SYM.ROM accepted and a wrong one refused, a file on the card never
// overwritten, a folder given to the folder chooser, the browser that cannot
// write (downloads), and the page opened from file://, as from the card.
// Not checked: a real SD card, Windows, Edge, a drop with the mouse.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const PKG = path.join(ROOT, 'pkg', 'pocket');
const LIST = 'plasticbugs.ngage';

const args = { html: path.join(PKG, 'Assets', 'ngage', 'common', 'Add N-Gage games.html') };
for (let i = 2; i < process.argv.length; i++) {
  const k = process.argv[i], v = () => process.argv[++i];
  if (k === '--games') args.games = v(); else if (k === '--rom') args.rom = v();
  else if (k === '--chrome') args.chrome = v(); else if (k === '--html') args.html = v();
  else { console.error('unknown argument ' + k); process.exit(2); }
}
if (!args.games) { console.error('usage: check_mkdrive_page.mjs --games DIR [--rom SYM.ROM] [--chrome PATH] [--html PAGE]'); process.exit(2); }

function findChrome() {
  const cands = [args.chrome, process.env.CHROME_PATH,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/usr/bin/google-chrome', '/usr/bin/chromium'];
  const pw = path.join(os.homedir(), 'Library', 'Caches', 'ms-playwright');
  if (fs.existsSync(pw)) for (const d of fs.readdirSync(pw).filter(d => /^chromium_headless_shell-/.test(d)).sort().reverse())
    for (const a of ['chrome-headless-shell-mac-arm64', 'chrome-headless-shell-mac-x64', 'chrome-headless-shell-linux64'])
      cands.push(path.join(pw, d, a, 'chrome-headless-shell'));
  const c = cands.find(c => c && fs.existsSync(c));
  if (!c) { console.error('no Chrome found: give --chrome PATH'); process.exit(2); }
  return c;
}

const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ngage-page-'));
let failures = 0;
const check = (ok, what, detail) => {
  console.log((ok ? '  ok    ' : '  FAIL  ') + what + (ok || !detail ? '' : ': ' + detail));
  if (!ok) failures++;
};

// ------------------------------------------------------------ the references
const zips = fs.readdirSync(args.games).filter(f => /\.zip$/i.test(f)).sort().map(f => path.join(args.games, f));
if (!zips.length) { console.error('no .zip in ' + args.games); process.exit(2); }
const want = new Map();
for (const [i, z] of zips.entries()) {
  const out = path.join(tmp, 'ref' + i + '.img');
  execFileSync('python3', [path.join(ROOT, 'tools', 'mkdrive.py'), '--from', z, '--out', out], { stdio: 'pipe' });
  want.set(z, sha(fs.readFileSync(out)));
  fs.rmSync(out);
}
const shipped = Object.fromEntries(fs.readdirSync(path.join(PKG, 'Assets', 'ngage', LIST)).filter(f => f.endsWith('.json'))
  .map(f => [f, fs.readFileSync(path.join(PKG, 'Assets', 'ngage', LIST, f), 'utf8')]));
const dataJson = fs.readFileSync(path.join(PKG, 'Cores', LIST, 'data.json'), 'utf8');

// ------------------------------------------------------------ a page server and Chrome
const server = http.createServer((req, res) => {
  if (req.url === '/') { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(fs.readFileSync(args.html)); }
  else { res.writeHead(404); res.end(); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const URL_ = 'http://127.0.0.1:' + server.address().port + '/';

const chrome = spawn(findChrome(), ['--headless', '--remote-debugging-port=0', '--user-data-dir=' + path.join(tmp, 'profile'),
  '--no-first-run', '--no-default-browser-check', '--allow-file-access-from-files', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const wsUrl = await new Promise((res, rej) => {
  let err = '';
  chrome.stderr.on('data', d => { err += d; const m = /DevTools listening on (ws:\/\/\S+)/.exec(err); if (m) res(m[1]); });
  chrome.on('exit', c => rej(new Error('Chrome exited ' + c + ': ' + err)));
});

const ws = new WebSocket(wsUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let seq = 0;
const pending = new Map(), listeners = new Set();
ws.onmessage = m => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) {
    const { res, rej } = pending.get(msg.id); pending.delete(msg.id);
    msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
  } else for (const l of listeners) l(msg);
};
const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
  const id = ++seq; pending.set(id, { res, rej });
  ws.send(JSON.stringify({ id, method, params, sessionId }));
});
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function openPage(stub) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const p = {
    send: (m, a) => send(m, a, sessionId),
    errors: [],
    async eval(expr) {
      const r = await this.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
      if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
      return r.result.value;
    },
    async go(url) {
      const loaded = new Promise(res => { const l = m => { if (m.sessionId === sessionId && m.method === 'Page.loadEventFired') { listeners.delete(l); res(); } }; listeners.add(l); });
      await this.send('Page.navigate', { url });
      await loaded;
    },
    async files(selector, list) {
      const { root } = await this.send('DOM.getDocument', {});
      const { nodeId } = await this.send('DOM.querySelector', { nodeId: root.nodeId, selector });
      await this.send('DOM.setFileInputFiles', { nodeId, files: list });
    },
    async until(expr, what, ms = 120000) {
      const t = Date.now();
      for (;;) {
        if (await this.eval(expr)) return true;
        if (Date.now() - t > ms) { check(false, what, 'timed out'); return false; }
        await sleep(200);
      }
    },
    close: () => send('Target.closeTarget', { targetId }),
  };
  listeners.add(m => {
    if (m.sessionId !== sessionId) return;
    if (m.method === 'Runtime.exceptionThrown') p.errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') p.errors.push(m.params.args.map(a => a.value ?? a.description).join(' '));
  });
  await p.send('Page.enable'); await p.send('Runtime.enable'); await p.send('DOM.enable');
  if (stub) await p.send('Page.addScriptToEvaluateOnNewDocument', { source: stub });
  return p;
}

// the card: a folder "card" in OPFS; window.__pick says which folder in it the
// person chooses
const PICKER = `window.showDirectoryPicker = async () => {
  let d = await (await navigator.storage.getDirectory()).getDirectoryHandle('card');
  for (const p of (window.__pick || '').split('/').filter(Boolean)) d = await d.getDirectoryHandle(p);
  return d;
};`;
const OPFS = `
  window.__dir = async (p, create) => { let d = await (await navigator.storage.getDirectory()).getDirectoryHandle('card', { create: !!create });
    for (const x of p.split('/').filter(Boolean)) d = await d.getDirectoryHandle(x, { create: !!create }); return d; };
  window.__put = async (p, text) => { const i = p.lastIndexOf('/'); const d = await __dir(p.slice(0, i), true);
    const w = await (await d.getFileHandle(p.slice(i + 1), { create: true })).createWritable(); await w.write(text); await w.close(); };
  window.__get = async (p) => { const i = p.lastIndexOf('/'); const d = await __dir(p.slice(0, i));
    try { return await (await d.getFileHandle(p.slice(i + 1))).getFile(); } catch (e) { return null; } };
  window.__sha = async (p) => { const f = await __get(p); if (!f) return null;
    return [...new Uint8Array(await crypto.subtle.digest('SHA-256', await f.arrayBuffer()))].map(b => b.toString(16).padStart(2, '0')).join(''); };
  window.__text = async (p) => { const f = await __get(p); return f && f.text(); };
  window.__ls = async (p) => { const out = []; try { for await (const [n] of (await __dir(p)).entries()) out.push(n); } catch (e) {} return out.sort(); };
  window.__tiles = () => [...document.querySelectorAll('#tiles .tile')].map(t => ({ state: t.dataset.state,
    name: t.querySelector('.tile-name').textContent, note: t.querySelector('.tile-note').textContent }));
  window.__settled = () => document.querySelectorAll('#tiles .tile').length > 0 && !document.querySelector('#tiles .tile[data-state="busy"], #tiles .tile[data-state="wait"]');
`;
async function freshCard(p, files) {
  await p.eval(OPFS + `(async () => { const r = await navigator.storage.getDirectory();
    for await (const [n] of r.entries()) await r.removeEntry(n, { recursive: true });
    await r.getDirectoryHandle('card', { create: true }); })()`);
  for (const [f, text] of Object.entries(files)) await p.eval(`__put(${JSON.stringify(f)}, ${JSON.stringify(text)})`);
}
const J = s => JSON.stringify(s);
const gameJson = (img, sav) => JSON.stringify({ instance: { magic: 'APF_VER_1', variant_select: { id: 0, select: false }, data_path: '',
  data_slots: [{ id: 3, filename: img }, ...(sav ? [{ id: 4, filename: sav }] : [])] } }, null, 4) + '\n';

// ------------------------------------------------------------ 1: a card with the core, all the games at once
console.log('a card with the core and saves; every game, SYM.ROM, one game twice, and a file that is not a game, in one go');
{
  const p = await openPage(PICKER);
  await p.go(URL_);
  const card = { 'Cores/plasticbugs.ngage/data.json': dataJson, 'Assets/ngage/common/ngvm.bin': 'kernel' };
  for (const [f, t] of Object.entries(shipped)) card['Assets/ngage/' + LIST + '/' + f] = t;
  await freshCard(p, card);
  fs.writeFileSync(path.join(tmp, 'readme.txt'), 'not a game\n');
  // the games before the card: they wait for it
  const batch = [...zips, zips[0], path.join(tmp, 'readme.txt'), ...(args.rom ? [args.rom] : [])];
  await p.files('#files', batch);
  await sleep(500);
  const waiting = await p.eval('__tiles()');
  check(waiting.length === batch.length && waiting.every(t => t.state === 'wait' && /SD card/.test(t.note)), 'before a card is chosen, everything waits for it',
    J(waiting.map(t => t.state + ' ' + t.note)));
  await p.eval(`window.__pick = ''; document.getElementById('pick').click()`);
  await p.until('__settled()', 'every game made and saved', 300000);
  const tiles = await p.eval('__tiles()');
  const tally = await p.eval(`document.getElementById('tally').textContent`);
  for (const [i, z] of zips.entries()) {
    const t = tiles[i], name = path.basename(z);
    const j = t && await p.eval(`__text(${J('Assets/ngage/' + LIST + '/' + t.name + '.json')})`);
    const slots = j ? JSON.parse(j).instance.data_slots : [];
    const img = slots.find(s => s.id === 3)?.filename;
    const got = img && await p.eval(`__sha(${J('Assets/ngage/common/' + img)})`);
    check(t && t.state === 'done' && got === want.get(z), name + ' is mkdrive.py\'s image, as ' + J(t && t.name), J(t) + ' ' + img);
    if (shipped[t.name + '.json']) check(j === shipped[t.name + '.json'], '  its menu entry is the one the core ships', j);
    else check(j === gameJson(img, img.replace(/\.img$/, '.sav')), '  its menu entry names the image and a save', j);
  }
  const dup = tiles[zips.length];
  const dupJson = dup && await p.eval(`__text(${J('Assets/ngage/' + LIST + '/' + dup.name + '.json')})`);
  const dupImg = dupJson && JSON.parse(dupJson).instance.data_slots[0].filename;
  check(dup && dup.state === 'done' && dup.name === tiles[0].name + ' 2' && dupImg && dupImg !== JSON.parse(await p.eval(`__text(${J('Assets/ngage/' + LIST + '/' + tiles[0].name + '.json')})`)).instance.data_slots[0].filename
    && await p.eval(`__sha(${J('Assets/ngage/common/' + dupImg)})`) === want.get(zips[0]), 'the same game twice is two entries, neither over the other', J(dup) + ' ' + dupImg);
  const junk = tiles[zips.length + 1];
  check(junk && junk.state === 'error' && /isn’t a game/.test(junk.note), 'a text file is refused, and says why', J(junk));
  if (args.rom) {
    const rom = tiles[zips.length + 2];
    check(rom && rom.state === 'done' && await p.eval(`__sha('Assets/ngage/common/sym.rom')`) === sha(fs.readFileSync(args.rom)), 'SYM.ROM is checked and saved as sym.rom', J(rom));
  }
  check(/couldn’t be used/.test(tally) && /on your SD card/.test(tally), 'the tally says what happened', tally);
  const checks = await p.eval(`document.getElementById('checks').textContent`);
  check(/core is on it/.test(checks) && (!args.rom || /SYM\.ROM is on it/.test(checks)), 'the card panel sees the core and SYM.ROM', checks);
  const common = await p.eval(`__ls('Assets/ngage/common')`);
  check(!common.some(n => /crswap|\.tmp$/i.test(n)), 'nothing half-written is left on the card', J(common));

  // rename the second copy
  const i = zips.length;
  await p.eval(`document.querySelectorAll('#tiles .tile')[${i}].querySelector('.tile-extra .link').click()`);
  await p.eval(`(() => { const t = document.querySelectorAll('#tiles .tile')[${i}]; t.querySelector('input').value = 'My Second Copy'; t.querySelector('.tile-extra .btn').click(); })()`);
  await sleep(500);
  const list = await p.eval(`__ls('Assets/ngage/${LIST}')`);
  const renamed = await p.eval(`__text('Assets/ngage/${LIST}/My Second Copy.json')`);
  check(list.includes('My Second Copy.json') && !list.includes(dup.name + '.json') && renamed === dupJson, 'renaming moves the menu entry and keeps its image', J(list));
  // a name another game has is refused
  await p.eval(`document.querySelectorAll('#tiles .tile')[${i}].querySelector('.tile-extra .link').click()`);
  await p.eval(`(() => { const t = document.querySelectorAll('#tiles .tile')[${i}]; t.querySelector('input').value = ${J(tiles[1].name)}; t.querySelector('.tile-extra .btn').click(); })()`);
  await sleep(300);
  const clash = await p.eval(`document.querySelectorAll('#tiles .tile')[${i}].querySelector('.tile-extra p').textContent`);
  check(/already a game called/.test(clash), 'a name another game has is refused', clash);
  check(!p.errors.length, 'no script errors', J(p.errors));
  await p.close();
}

// ------------------------------------------------------------ 2: the Assets folder of an older card
console.log('the Assets folder of a card whose menu has no saves, with an image of its own');
{
  const p = await openPage(PICKER);
  await p.go(URL_);
  const sn = zips.find(z => /snakes/i.test(path.basename(z))), pu = zips.find(z => /puyo/i.test(path.basename(z)));
  await freshCard(p, {
    'Assets/ngage/common/ngvm.bin': 'kernel',
    'Assets/ngage/common/puyo.img': 'the person\'s own file',
    'Assets/ngage/common/sym.rom': 'too short',
    ['Assets/ngage/' + LIST + '/Snakes.json']: gameJson('snakes.img'),
  });
  await p.eval(`window.__pick = 'Assets/ngage/common'; document.getElementById('pick').click()`);
  await sleep(500);
  const wrong = await p.eval(`document.getElementById('checks').textContent`);
  check(/inside the card’s Assets folder/.test(wrong), 'choosing a folder inside Assets says to choose Assets', wrong);
  await p.eval(`window.__pick = 'Assets'; document.getElementById('pick').click()`);
  await p.until(`!document.getElementById('card-box').hidden && /wrong one/.test(document.getElementById('checks').textContent)`, 'a sym.rom of the wrong size is reported');
  const batch = [sn, pu].filter(Boolean);
  if (args.rom) {
    fs.writeFileSync(path.join(tmp, 'bad.rom'), Buffer.alloc(1024));
    batch.push(path.join(tmp, 'bad.rom'));
  }
  await p.files('#files', batch);
  await p.until('__settled()', 'the games made and saved');
  if (sn) {
    const j = await p.eval(`__text('Assets/ngage/${LIST}/Snakes.json')`);
    check(j === gameJson('snakes.img') && await p.eval(`__sha('Assets/ngage/common/snakes.img')`) === want.get(sn), 'a listed game replaces its image, and a menu without saves gets none', j);
  }
  if (pu) {
    const j = await p.eval(`__text('Assets/ngage/${LIST}/Puyo Pop.json')`);
    check(j === gameJson('puyo-2.img') && await p.eval(`__text('Assets/ngage/common/puyo.img')`) === 'the person\'s own file'
      && await p.eval(`__sha('Assets/ngage/common/puyo-2.img')`) === want.get(pu), 'a file already on the card is never overwritten', j);
  }
  if (args.rom) {
    const t = (await p.eval('__tiles()')).at(-1);
    check(t.state === 'error' && /18,612,224/.test(t.note), 'a file that is not SYM.ROM is refused, and says why', J(t));
  }
  // a game's folder, given to the folder chooser
  const unz = path.join(tmp, 'unzipped', 'Virtua Cop');
  const vc = zips.find(z => /virtua/i.test(path.basename(z)));
  if (vc) {
    fs.mkdirSync(unz, { recursive: true });
    execFileSync('unzip', ['-q', vc, '-d', unz]);
    const before = (await p.eval('__tiles()')).length;
    try {
      await p.files('#folder', [unz]);
      await p.until(`document.querySelectorAll('#tiles .tile').length > ${before} && __settled()`, 'the folder made and saved');
      const t = (await p.eval('__tiles()')).at(-1);
      const j = await p.eval(`__text(${J('Assets/ngage/' + LIST + '/' + t.name + '.json')})`);
      const img = j && JSON.parse(j).instance.data_slots[0].filename;
      // mkdrive.py's image of the folder (a folder has no zip's empty directories)
      const out = path.join(tmp, 'folder.img');
      execFileSync('python3', [path.join(ROOT, 'tools', 'mkdrive.py'), '--from', unz, '--out', out], { stdio: 'pipe' });
      check(t.state === 'done' && img && await p.eval(`__sha(${J('Assets/ngage/common/' + img)})`) === sha(fs.readFileSync(out)), 'a game\'s folder is mkdrive.py\'s image of that folder', J(t));
    } catch (e) { console.log('  skip  the folder chooser: ' + e.message); }
  }
  check(!p.errors.length, 'no script errors', J(p.errors));
  await p.close();
}

// ------------------------------------------------------------ 3: a browser that cannot write
console.log('a browser without the folder picker: the files download');
{
  const dl = path.join(tmp, 'downloads');
  fs.mkdirSync(dl);
  const p = await openPage('window.showDirectoryPicker = undefined;');
  await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dl });
  await p.go(URL_);
  await p.eval(OPFS);
  const sn = zips.find(z => /snakes/i.test(path.basename(z))) || zips[0];
  await p.files('#files', [sn, ...(args.rom ? [args.rom] : [])]);
  await p.until('__settled()', 'ready to download');
  const tiles = await p.eval('__tiles()');
  check(tiles.every(t => t.state === 'ready'), 'each is ready to download', J(tiles));
  // rename the game, so its menu entry downloads too
  await p.eval(`(() => { const t = document.querySelectorAll('#tiles .tile')[0]; [...t.querySelectorAll('.link')].find(b => b.textContent === 'Rename').click(); })()`);
  await p.eval(`(() => { const t = document.querySelectorAll('#tiles .tile')[0]; t.querySelector('input').value = 'My Game'; t.querySelector('.tile-extra .btn').click(); })()`);
  await sleep(300);
  await p.eval(`document.querySelectorAll('#tiles .tile').forEach(t => [...t.querySelectorAll('button')].find(b => b.textContent === 'Download').click())`);
  const files = () => fs.readdirSync(dl).filter(f => !f.endsWith('.crdownload'));
  for (let i = 0; i < 100 && files().length < (args.rom ? 3 : 2); i++) await sleep(200);
  const got = files().sort();
  check(got.includes('my-game.img') && sha(fs.readFileSync(path.join(dl, 'my-game.img'))) === want.get(sn), 'the image downloads, named after the menu name', J(got));
  check(got.includes('My Game.json') && fs.readFileSync(path.join(dl, 'My Game.json'), 'utf8') === gameJson('my-game.img', 'my-game.sav'), 'its menu entry downloads too', J(got));
  if (args.rom) check(got.includes('sym.rom') && sha(fs.readFileSync(path.join(dl, 'sym.rom'))) === sha(fs.readFileSync(args.rom)), 'SYM.ROM downloads as sym.rom', J(got));
  check(!p.errors.length, 'no script errors', J(p.errors));
  await p.close();
}

// ------------------------------------------------------------ 4: opened from the card
console.log('the page opened as a file, as from the SD card');
{
  const p = await openPage();
  await p.go('file://' + path.resolve(args.html));
  // fonts.load() names the faces it loaded, and none when the page has no such face
  const r = await p.eval(`(async () => ({ secure: isSecureContext, picker: typeof showDirectoryPicker, time: document.getElementById('time').textContent,
    font: (await Promise.all(['800 20px "Barlow Condensed"', '400 20px Barlow', '600 20px Barlow'].map(f => document.fonts.load(f, 'N-Gage'))))
      .every(l => l.length && l.every(f => f.status === 'loaded')),
    parts: document.querySelectorAll('#scrub button').length }))()`);
  check(r.secure && r.picker === 'function', 'a file:// page may use the folder picker', J(r));
  check(r.parts === 8 && /^0:00 \/ 1:\d\d$/.test(r.time) && r.font, 'the film is ready and the type is the page\'s own', J(r));
  // a real click, so the browser lets the page start its sound
  const at = await p.eval(`(() => { const b = document.getElementById('play'); b.scrollIntoView(); const r = b.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
  for (const type of ['mousePressed', 'mouseReleased'])
    await p.send('Input.dispatchMouseEvent', { type, x: at[0], y: at[1], button: 'left', clickCount: 1 });
  await sleep(2500);
  const t = await p.eval(`[document.getElementById('time').textContent, document.getElementById('play').textContent, document.querySelector('.caption .now')?.textContent, document.getElementById('stage').dataset.sound]`);
  check(/^0:0[12]/.test(t[0]) && t[1] === 'Pause' && t[2], 'the film plays, its captions following the voice', J(t));
  check(t[3] === 'on', 'with its sound: the narration and music decode and play', J(t));
  check(!p.errors.length, 'no script errors', J(p.errors));
  await p.close();
}

ws.close(); chrome.kill(); server.close();
fs.rmSync(tmp, { recursive: true, force: true });
console.log(failures ? failures + ' failed' : 'all passed');
process.exit(failures ? 1 : 0);
