// 不佔螢幕、不動滑鼠、不碰任何音量：用無頭瀏覽器把 App 內那一頁（Resources/slider.html）逐格算出來，
// 做成只拍滑桿本身的示範影片。時間是虛擬的（每格固定 1/60 秒 ×2），所以每一格都算得到、不會掉格。
// 用法：node scripts/render_demo.mjs <playwright 的 node_modules 所在資料夾> <輸出資料夾>
import { createRequire } from 'node:module';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , pwRoot, outDir] = process.argv;
const require = createRequire(path.join(pwRoot, 'x.js'));
const { chromium } = require('playwright');
const here = path.dirname(fileURLToPath(import.meta.url));
const page_url = 'file://' + path.resolve(here, '../Resources/slider.html');
fs.mkdirSync(path.join(outDir, 'frames'), { recursive: true });

const FPS = 30, W = 960, H = 540;
const browser = await chromium.launch({ headless: true, args: ['--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 2 });
page.on('pageerror', e => { console.error('PAGE ERROR', e.message); process.exitCode = 1; });

await page.addInitScript(() => {
  // 虛擬時鐘
  let vt = 0; const cbs = [];
  performance.now = () => vt;
  window.requestAnimationFrame = cb => { cbs.push(cb); return cbs.length; };
  window.__step = dt => { vt += dt * 1000; const q = cbs.splice(0); q.forEach(cb => cb(vt)); };
  // 假的原生端：記住音量與靜音，不碰任何真的裝置
  const st = { v: 0.35, muted: false, supported: true, device: 'MacBook Pro Speakers' };
  window.__st = st;
  window.__nativeStep = d => { st.v = Math.min(1, Math.max(0, Math.round(st.v * 16 + d) / 16)); if (d > 0) st.muted = false; window.__native.set({ ...st, snap: false }); };
  window.webkit = { messageHandlers: { vol: { postMessage(m) {
    if (m.ready) window.__native.set({ ...st, snap: true });
    if (typeof m.v === 'number') { st.v = m.v; if (m.v > 0.001 && st.muted) { st.muted = false; window.__native.set({ ...st, snap: false }); } }
    if (m.mute) { st.muted = !st.muted; window.__native.set({ ...st, snap: false }); }
  } } } };
});
await page.goto(page_url);
await page.addStyleTag({ content: `
  body { background: radial-gradient(120% 90% at 50% 40%, #2a2d4c 0%, #1a1b2c 55%, #11121d 100%) !important; }
  .label { font-size: 20px !important; } .value { font-size: 64px !important; } .hint { font-size: 20px !important; }
  #cur { position: fixed; left: 0; top: 0; width: 30px; height: 30px; margin: -15px 0 0 -15px; border-radius: 50%; border: 3px solid rgba(255,255,255,.9);
         background: rgba(255,255,255,.12); box-shadow: 0 2px 10px rgba(0,0,0,.5); pointer-events: none; z-index: 9; transition: transform .12s, background .12s; }
  #cur.down { transform: scale(.72); background: rgba(255,255,255,.45); }` });
await page.evaluate(() => {
  const c = document.createElement('div'); c.id = 'cur'; document.body.appendChild(c);
  addEventListener('mousemove', e => { c.style.left = e.clientX + 'px'; c.style.top = e.clientY + 'px'; }, true);
  addEventListener('mousedown', () => c.classList.add('down'), true); addEventListener('mouseup', () => c.classList.remove('down'), true);
});
for (let i = 0; i < 30; i++) await page.evaluate(() => window.__step(1 / 60));       // 先跑半秒讓版面排好

// 玻璃在畫面上的座標（跟頁面裡 layout() 同一組算式）
const g = await page.evaluate(() => {
  const r = document.getElementById('stage').getBoundingClientRect(), w = r.width;
  const padX = Math.max(18, w * 0.06), pillW = w - padX * 2, pillH = pillW / 3.727, b = pillH * 0.085, ix = padX + b, iw = pillW - 2 * b, rx = pillH * 0.36;
  const n = document.getElementById('num').getBoundingClientRect();
  return { x0: r.left + ix + rx * 0.55, x1: r.left + ix + iw - rx * 0.55, cy: r.top + r.height / 2, numX: n.left + n.width / 2, numY: n.top + n.height / 2 };
});
const X = p => g.x0 + p * (g.x1 - g.x0);
const ease = t => t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;

// 劇本：[開始秒, 結束秒, 動作]
const drags = [[1.0, 2.4, 0.35, 0.0], [3.9, 5.0, 0.0, 0.35], [6.3, 7.6, 0.35, 0.75], [9.7, 10.8, 0.75, 1.0], [13.1, 14.3, 1.0, 0.5]];
const clicks = [15.2, 17.4];                                   // 點數字：靜音、解除
const keys = [[18.6, 1], [18.9, 1], [19.2, 1], [19.5, 1], [20.6, -1], [20.9, -1], [21.2, -1], [21.5, -1]];
const stills = { 3.6: 'state-0', 6.0: 'state-35', 9.3: 'state-75', 12.7: 'state-100', 16.9: 'state-muted' };
const END = 23.0;
await page.mouse.move(X(0.35) + 60, g.cy + 150);

let down = false, done = new Set();
for (let f = 0; f < END * FPS; f++) {
  const t = f / FPS;
  const d = drags.find(d => t >= d[0] - 0.5 && t <= d[1] + 0.25);
  if (d) {
    if (t < d[0]) { const k = ease((t - (d[0] - 0.5)) / 0.5); const mp = await page.evaluate(() => [parseFloat(cur.style.left) || 0, parseFloat(cur.style.top) || 0]);
      await page.mouse.move(mp[0] + (X(d[2]) - mp[0]) * k, mp[1] + (g.cy - mp[1]) * k); }
    else if (t <= d[1]) { if (!down) { await page.mouse.move(X(d[2]), g.cy); await page.mouse.down(); down = true; }
      await page.mouse.move(X(d[2] + (d[3] - d[2]) * ease((t - d[0]) / (d[1] - d[0]))), g.cy); }
    else if (down && t >= d[1] + 0.2) { await page.mouse.up(); down = false; }
  }
  for (const c of clicks) {
    if (t >= c - 0.6 && t < c) { const k = ease((t - (c - 0.6)) / 0.6); const mp = await page.evaluate(() => [parseFloat(cur.style.left), parseFloat(cur.style.top)]);
      await page.mouse.move(mp[0] + (g.numX - mp[0]) * k, mp[1] + (g.numY - mp[1]) * k); }
    if (t >= c && !done.has('c' + c)) { done.add('c' + c); await page.mouse.move(g.numX, g.numY); await page.mouse.down(); }
    if (t >= c + 0.12 && !done.has('u' + c)) { done.add('u' + c); await page.mouse.up(); }
  }
  if (t >= 17.9 && t < 18.5) await page.mouse.move(g.numX + 250 * ease((t - 17.9) / 0.6), g.numY + 330 * ease((t - 17.9) / 0.6));   // 游標讓開，換鍵盤
  for (const [kt, dir] of keys) if (t >= kt && !done.has('k' + kt)) { done.add('k' + kt); await page.evaluate(d => window.__nativeStep(d), dir); }
  await page.evaluate(() => { window.__step(1 / 60); window.__step(1 / 60); });
  const file = path.join(outDir, 'frames', String(f).padStart(5, '0') + '.jpg');
  await page.screenshot({ path: file, type: 'jpeg', quality: 95 });
  for (const [st, name] of Object.entries(stills)) if (Math.abs(t - st) < 0.5 / FPS) { await page.evaluate(() => { cur.style.visibility = 'hidden'; }); await page.screenshot({ path: path.join(outDir, name + '.png') }); await page.evaluate(() => { cur.style.visibility = ''; }); }   // 截圖不帶游標
}
const final = await page.evaluate(() => ({ st: window.__st, shown: document.getElementById('num').textContent }));
console.log('frames', END * FPS, 'final', JSON.stringify(final));
await browser.close();
