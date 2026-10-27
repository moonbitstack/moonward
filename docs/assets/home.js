import { engine, ready } from "./engine.js";
import * as C from "./chart.js";

const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/* --- the hero panel ------------------------------------------------------ */

const canvas = document.getElementById("hero-scope");
const reads = {
  ratio: document.querySelector('[data-read="ratio"]'),
  clock: document.querySelector('[data-read="clock"]'),
  sent: document.querySelector('[data-read="sent"]'),
  failed: document.querySelector('[data-read="failed"]'),
  refused: document.querySelector('[data-read="refused"]'),
};

const TICK_MS = 46;
const HOLD_MS = 2600;

let scene = null;
let shown = 0;
let startedAt = 0;
let held = 0;
let raf = 0;
let over = false;

function run(randomise) {
  const call = engine();
  if (!call) {
    offline();
    return;
  }
  const from = randomise ? 1200 + Math.round(Math.random() * 1600) : 2000;
  const to = from + 2600 + Math.round(Math.random() * 2200);
  const seed = randomise ? 1 + Math.floor(Math.random() * 99991) : 47;
  scene = JSON.parse(call(0, 20, from, to, 10000, 10000, seed, 0));
  scene.fault = [from, to];
  shown = reduce ? scene.ratio.length : 0;
  startedAt = performance.now();
  held = 0;
  if (!raf) raf = requestAnimationFrame(frame);
  paint();
}

function offline() {
  over = true;
  const { ctx, w, h } = C.fit(canvas);
  const p = C.palette();
  C.grid(ctx, w, h, 4, p.line);
  C.corners(ctx, w, h, p.line);
  ctx.save();
  ctx.strokeStyle = p.hot;
  ctx.globalAlpha = 0.5;
  ctx.lineWidth = 1;
  ctx.setLineDash([4, 4]);
  ctx.beginPath();
  ctx.moveTo(0, h);
  ctx.lineTo(w, 0);
  ctx.stroke();
  ctx.restore();
  C.note(ctx, "ENGINE NOT BUILT", p.hot, 10, h / 2);
  if (reads.ratio) reads.ratio.textContent = "--";
}

function paint() {
  if (!scene) return;
  const { ctx, w, h } = C.fit(canvas);
  const p = C.palette();

  C.grid(ctx, w, h, 4, p.line, 2);
  C.band(ctx, w, h, scene.fault[0] / 10000, scene.fault[1] / 10000, p.hot);

  const maxDrop = Math.max(4, ...scene.drop);
  C.bars(ctx, w, h, scene.drop, maxDrop, p.hot, shown);
  C.stepLine(ctx, w, h, scene.ratio, 1000, p.ink, shown);
  C.corners(ctx, w, h, p.line);

  const tail = Math.min(shown, scene.drop.length);
  const refused = scene.drop.slice(0, tail).reduce((a, b) => a + b, 0);
  const failed = scene.fail.slice(0, tail).reduce((a, b) => a + b, 0);
  const passed = scene.pass.slice(0, tail).reduce((a, b) => a + b, 0);
  const ratio = tail > 0 ? scene.ratio[tail - 1] / 10 : 0;

  if (reads.ratio) reads.ratio.textContent = ratio.toFixed(1);
  if (reads.clock) reads.clock.textContent = ((tail * 100) / 1000).toFixed(1);
  if (reads.sent) reads.sent.textContent = String(passed + failed);
  if (reads.failed) reads.failed.textContent = String(failed);
  if (reads.refused) reads.refused.textContent = String(refused);

  C.note(ctx, "REFUSED / 100 MS", p.hot, 10, 14);
  ctx.save();
  ctx.fillStyle = p.ink;
  ctx.globalAlpha = 0.85;
  ctx.font = '500 9px "IBM Plex Mono", monospace';
  ctx.textAlign = "right";
  ctx.fillText("RATIO %", w - 10, 14);
  ctx.restore();
}

function frame(now) {
  if (!scene) {
    raf = 0;
    return;
  }
  const elapsed = now - startedAt;
  const target = Math.min(scene.ratio.length, Math.floor(elapsed / TICK_MS));
  if (target !== shown) {
    shown = target;
    paint();
  }
  if (shown >= scene.ratio.length) {
    if (!held) held = now;
    if (!reduce && now - held > HOLD_MS) {
      run(true);
    }
    raf = requestAnimationFrame(frame);
    return;
  }
  raf = requestAnimationFrame(frame);
}

for (const btn of document.querySelectorAll("[data-act]")) {
  btn.addEventListener("click", () => {
    if (!ready()) {
      offline();
      return;
    }
    run(btn.dataset.act === "fault");
  });
}

if (canvas) {
  new ResizeObserver(() => paint()).observe(canvas);
  C.onTheme(() => paint());
  if (ready()) {
    run(false);
  } else {
    // The bundle may still be loading; give it a moment, then say so.
    window.setTimeout(() => {
      if (ready()) run(false);
      else offline();
    }, 600);
  }
}
