#!/usr/bin/env python3
"""把 prototype/glass.html（網頁原型）轉成 App 用的 Resources/slider.html。
原型自帶的合成音樂與刻度聲不會啟動；音量改由原生端（macOS 系統音量）雙向同步。"""
import pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
s = (root / 'prototype' / 'glass.html').read_text(encoding='utf-8')

def rep(a, b, n=1):
    global s
    assert s.count(a) == n, f'expected {n} of: {a[:60]!r}, found {s.count(a)}'
    s = s.replace(a, b)

# 外觀：透明底（讓選單列彈出視窗的材質透出來）、固定寬度、拿掉版本切換列
rep("background: radial-gradient(120% 90% at 50% 40%, #262842 0%, #1a1b2c 55%, #131420 100%);", "background: transparent;")
rep("canvas { width: min(96vw, 980px);", "canvas { width: 100%;")
rep('  <div class="alt">液態玻璃版 Liquid Glass · <a href="index.html">像素版 Pixel</a></div>\n', '')
rep('<div class="hint" id="hint">拖曳玻璃，把音樂開大聲 · Drag the glass to turn the music up</div>', '<div class="hint" id="hint">&nbsp;</div>')
rep(".value { font-size: clamp(40px, 9vw, 76px);", ".value { cursor: pointer; font-size: 9vw;")
rep("  .hint.gone { opacity: 0; }\n", "  .off canvas { opacity: .4; pointer-events: none; }\n  .muted .value { color: #8f93b8; }\n")
rep(".label { font-size: 13px; letter-spacing: .28em;", ".label { font-size: max(9px, 2.9vw); letter-spacing: .28em;")
rep(".hint { font-size: 14px;", ".hint { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; box-sizing: border-box; font-size: max(10px, 2.9vw);")
rep("    gap: 6px; overflow: hidden;", "    gap: 2px; overflow: hidden;")
rep("<title>液態玻璃音量滑桿 · Liquid Glass Volume</title>", "<title>UTUVO Volume</title>")

# 不啟動合成音樂；節拍用固定時鐘
rep("const started = () => { initAudio(); hintEl.classList.add('gone'); };", "const started = () => {};")

# 原生橋接
rep("let geo = null, lastT = performance.now()", """let muted = false, supported = true, paused = false, nativeTarget = -1, lastPosted = -1, lastPostT = 0;
const post = m => { try { window.webkit.messageHandlers.vol.postMessage(m); } catch (e) {} };
window.__native = {
  set(st) {                                   // 原生端推來的系統音量狀態
    muted = !!st.muted; supported = !!st.supported;
    document.body.classList.toggle('off', !supported); document.body.classList.toggle('muted', muted);
    hintEl.textContent = supported ? (st.device || '') + (muted ? ' · 靜音 Muted' : '') : (st.device || '') + ' · 此輸出無法調音量 Fixed volume';
    if (!dragging && performance.now() - lastPostT > 300 && typeof st.v === 'number') { nativeTarget = target = clamp(st.v, 0, 1); if (st.snap) { pos = target; vel = 0; } }
  },
  pause(p) { paused = !!p; }
};
document.querySelector('.value').addEventListener('click', () => post({ mute: 'toggle' }));
let geo = null, lastT = performance.now()""")
rep("  if (geo.w < 120) { lastT = now; requestAnimationFrame(frame); return; }",
    "  if (geo.w < 120) { lastT = now; requestAnimationFrame(frame); return; }\n  if (paused) { lastT = now; setTimeout(() => requestAnimationFrame(frame), 400); return; }")
# 送出去的是手指的位置（target），不是彈簧位置，所以不會過衝
rep("  v = clamp(pos, 0, 1);\n", "  v = clamp(pos, 0, 1);\n  if (target !== nativeTarget && target !== lastPosted) { lastPosted = target; lastPostT = now; post({ v: target }); }\n  const vv = (muted || !supported) ? 0 : v;\n")
rep("drawScene(gA, false, v, tt, beat); drawScene(gB, true, v, tt, beat);", "drawScene(gA, false, vv, tt, beat); drawScene(gB, true, vv, tt, beat);")
rep("    if (v > 0.15) for (let i = 0, m = Math.ceil(v * 3)", "    if (vv > 0.15) for (let i = 0, m = Math.ceil(vv * 3)")
rep("  if (v > 0.9 && !reduceMotion) {", "  if (vv > 0.9 && !reduceMotion) {")
rep("layout(); requestAnimationFrame(frame);", "layout(); requestAnimationFrame(frame); post({ ready: true });")
(root / 'Resources' / 'slider.html').write_text(s, encoding='utf-8')
print('slider.html', len(s))
