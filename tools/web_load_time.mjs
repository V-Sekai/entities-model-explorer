// Cold load time of the Godot web export in Chrome: a fresh profile (no HTTP cache, no shader
// cache in IndexedDB), from the start of the navigation to the page's "BOOT loaded" console line,
// which boot.gd prints after the sample model is on screen. Prints "WEB-LOAD-MS <ms>" (or
// "WEB-LOAD-MS none (...)") and the browser build it used.
// usage: node web_load_time.mjs <page url> [limit seconds, default 120]
//
// Browser: the newest Playwright Chromium build that can navigate. Chromium 1248 (Chrome for
// Testing, headless) never answers Page.navigate on the Mac mini, so each build is first tried on
// a same-origin page and skipped when it does not answer within 15 s.
import { spawn } from 'node:child_process';
import { mkdtempSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';

const url = process.argv[2];
const limit = +(process.argv[3] || 120) * 1000;
const pw = `${process.env.HOME}/Library/Caches/ms-playwright`;
const builds = readdirSync(pw).filter((d) => /^chromium-\d+$/.test(d)).sort((a, b) => +b.split('-')[1] - +a.split('-')[1]);
const sleep = (ms) => new Promise((r) => { setTimeout(r, ms); });
const within = (p, ms) => Promise.race([p, sleep(ms).then(() => null)]);

async function open(build, port) {
  const exe = `${pw}/${build}/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
  const br = spawn(exe, ['--headless=new', `--remote-debugging-port=${port}`, '--no-first-run',
    `--user-data-dir=${mkdtempSync(tmpdir() + '/wl')}`, 'about:blank'], { stdio: 'ignore' });
  let targets = null;
  for (let i = 0; i < 80 && !targets; i++) {
    await sleep(250);
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch { targets = null; }
  }
  const page = targets && targets.find((x) => x.type === 'page');
  if (!page) { br.kill(); return null; }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => { ws.onopen = r; });
  const s = { br, ws, id: 0, pending: {}, booted: null, fail: null };
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && s.pending[d.id]) { s.pending[d.id](d); delete s.pending[d.id]; return; }
    if (d.method === 'Runtime.consoleAPICalled') {
      const text = d.params.args.map((a) => a.value ?? a.description ?? '').join(' ');
      if (s.booted === null && /BOOT loaded/.test(text)) s.booted = d.params.timestamp;
    } else if (d.method === 'Runtime.exceptionThrown') {
      s.fail = d.params.exceptionDetails.exception?.description || d.params.exceptionDetails.text;
    }
  };
  s.send = (method, params = {}) => new Promise((r) => { s.pending[++s.id] = r; ws.send(JSON.stringify({ id: s.id, method, params })); });
  return s;
}

// A cross-origin-isolated page (COOP same-origin) opened from about:blank swaps the renderer; a
// same-origin page with the same headers first (the server's 404 for /__blank carries them) keeps
// the timed load in the session that listens to it.
let s = null; let used = null; const skipped = [];
for (const [i, b] of builds.entries()) {
  const t = await open(b, 9400 + i);
  if (t && await within(t.send('Runtime.enable'), 15000) && await within(t.send('Page.navigate', { url: new URL('/__blank', url).href }), 15000)) {
    s = t; used = b; break;
  }
  if (t) t.br.kill();
  skipped.push(b);
}
if (!s) { console.log(`WEB-LOAD-MS none (no Chromium build navigates: ${skipped.join(', ')})`); process.exit(0); }
await s.send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
// Console timestamps are wall-clock ms; nothing is evaluated in the page while it loads (a loading
// engine can hold the main thread for seconds).
const t0 = Date.now();
s.send('Page.navigate', { url });
while (s.booted === null && Date.now() - t0 < limit) await sleep(100);
const why = s.fail ? `; ${s.fail.split('\n')[0]}` : '';
console.log(s.booted === null ? `WEB-LOAD-MS none (no BOOT loaded in ${limit / 1000} s${why})` : `WEB-LOAD-MS ${Math.round(s.booted - t0)}`);
console.log(`WEB-LOAD-BROWSER ${used}${skipped.length ? ` (skipped ${skipped.join(', ')}: no answer to Page.navigate)` : ''}`);
s.br.kill();
process.exit(0);
