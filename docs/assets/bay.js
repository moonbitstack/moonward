import { engine, ready } from "./engine.js";
import * as C from "./chart.js";

const call = () => engine();
const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const status = document.getElementById("bay-status");

const val = (id) => Number(document.getElementById(id).value);
const out = (name) => document.querySelector(`[data-out="${name}"]`);
const say = (name) => document.querySelector(`[data-say="${name}"]`);
const put = (name, text) => {
  const node = out(name);
  if (node) node.textContent = text;
};
const tell = (name, text) => {
  const node = say(name);
  if (node && text) node.textContent = text;
};

/* --- animated sweep ------------------------------------------------------ */

const benches = new Map();

function bench(id, canvasIds, compute, draw, report) {
  const entry = {
    id,
    canvases: canvasIds.map((c) => document.getElementById(c)),
    compute,
    draw,
    report,
    data: null,
    upto: 0,
    raf: 0,
    at: 0,
  };
  benches.set(id, entry);
  return entry;
}

function measure(entry) {
  entry.data = entry.compute();
  entry.upto = reduce ? length(entry) : 0;
  entry.at = performance.now();
  if (!entry.raf) entry.raf = requestAnimationFrame(() => tick(entry));
  entry.report(entry.data, entry.upto);
  entry.draw(entry.upto);
}

function length(entry) {
  const d = entry.data;
  if (!d) return 0;
  return d.ratio ? d.ratio.length : d.bucket ? d.bucket.length : d.flying ? d.flying.length : 1;
}

function tick(entry) {
  const total = length(entry);
  const elapsed = performance.now() - entry.at;
  const target = reduce ? total : Math.min(total, Math.round((elapsed / 460) * total));
  if (target !== entry.upto) {
    entry.upto = target;
    entry.draw(entry.upto);
    entry.report(entry.data, entry.upto);
  }
  if (entry.upto < total) {
    entry.raf = requestAnimationFrame(() => tick(entry));
  } else {
    entry.raf = 0;
  }
}

/* --- knobs --------------------------------------------------------------- */

function knob(id, format, onChange) {
  const input = document.getElementById(id);
  if (!input) return;
  const label = document.querySelector(`output[for="${id}"]`);
  const sync = () => {
    if (label) label.textContent = format(Number(input.value));
    onChange();
  };
  input.addEventListener("input", sync);
  sync();
}

/* --- 01 breaker ---------------------------------------------------------- */

const breakerBench = bench(
  "b",
  ["b-scope"],
  () => {
    const interval = val("b-interval");
    const from = val("b-from") * 100;
    const to = from + val("b-len") * 100;
    const bp = val("b-bp") * 100;
    const data = JSON.parse(call()(0, interval, from, to, 10000, bp, 47, 0));
    data.fault = [from, to];
    return data;
  },
  (upto) => {
    const { ctx, w, h } = C.fit(breakerBench.canvases[0]);
    const p = C.palette();
    C.grid(ctx, w, h, 4, p.line, 2);
    if (breakerBench.data.fault) {
      C.band(ctx, w, h, breakerBench.data.fault[0] / 10000, breakerBench.data.fault[1] / 10000, p.hot);
    }
    const max = Math.max(3, ...breakerBench.data.drop);
    C.bars(ctx, w, h, breakerBench.data.drop, max, p.hot, upto);
    C.stepLine(ctx, w, h, breakerBench.data.ratio, 1000, p.ink, upto);
    C.corners(ctx, w, h, p.line);
  },
  (data, upto) => {
    const peak = Math.max(0, ...data.ratio) / 10;
    const tail = Math.min(upto, data.ratio.length);
    const refused = data.drop.slice(0, tail).reduce((a, b) => a + b, 0);
    const admitted = data.pass.slice(0, tail).reduce((a, b) => a + b, 0) +
      data.fail.slice(0, tail).reduce((a, b) => a + b, 0);
    put("b-peak", peak.toFixed(1) + "%");
    put("b-admitted", String(admitted));
    put("b-refused", String(refused));
    if (refused === 0) {
      tell("b", "Too few failures inside the ten-second window to refuse anything: the breaker is still passing calls.");
    } else if (data.ratio[tail - 1] < peak * 10 - 50) {
      tell("b", "The window forgets. The ratio peaked and is falling, because the bad buckets are ageing out of it.");
    } else {
      tell("b", "The refusal fraction is still climbing: a success pays for one and a half calls, so failures have to outweigh them.");
    }
  },
);

/* --- 02 limiters --------------------------------------------------------- */

const limiterBench = bench(
  "l",
  ["l-bucket", "l-sliding", "l-period"],
  () => JSON.parse(call()(1, val("l-demand"), val("l-quota"), val("l-burst"), 1000, 6000, 3)),
  (upto) => {
    const d = limiterBench.data;
    const p = C.palette();
    const series = [["bucket", d.bucket], ["sliding", d.sliding], ["period", d.period]];
    const max = Math.max(4, ...d.bucket, ...d.sliding, ...d.period);
    limiterBench.canvases.forEach((canvas, i) => {
      const { ctx, w, h } = C.fit(canvas);
      C.grid(ctx, w, h, 2, p.line, 1);
      const color = i === 2 ? p.hot : p.sig;
      C.bars(ctx, w, h, series[i][1], max, color, upto);
      C.corners(ctx, w, h, p.line);
      ctx.save();
      ctx.fillStyle = p.faint;
      ctx.font = '500 8.5px "IBM Plex Mono", monospace';
      ctx.fillText(String(max), w - 22, 10);
      ctx.restore();
    });
  },
  (data, upto) => {
    const tail = Math.min(upto, data.bucket.length);
    const sum = (a) => a.slice(0, tail).reduce((x, y) => x + y, 0);
    const offered = (data.demand * tail) / 10;
    put("l-sent", String(Math.round(offered)));
    put("l-b", String(sum(data.bucket)));
    put("l-s", String(sum(data.sliding)));
    put("l-p", String(sum(data.period)));
    const bucket = sum(data.bucket);
    const period = sum(data.period);
    const sliding = sum(data.sliding);
    if (period > sliding + 4) {
      tell("l", "The period is passing more than the slide: it starts a fresh quota when the second turns over, so a burst straddling the boundary is counted twice.");
    } else if (bucket > sliding + 4) {
      tell("l", "The bucket is ahead: it saved a burst and spent it, and it will sit at the rate afterwards.");
    } else {
      tell("l", "All three agree while the traffic stays under the rate. Push the traffic knob up and pull the quota down to separate them.");
    }
  },
);

/* --- 03 backoff ---------------------------------------------------------- */

const backoffBench = bench(
  "k",
  ["k-scope"],
  () =>
    JSON.parse(
      call()(2, val("k-base"), val("k-factor"), val("k-cap"), val("k-attempts"), val("k-jitter"), 11, 0),
    ),
  (upto) => {
    const d = backoffBench.data;
    const { ctx, w, h } = C.fit(backoffBench.canvases[0]);
    const p = C.palette();
    C.grid(ctx, w, h, 4, p.line, 2);
    const max = Math.max(1, ...d.ceiling, ...d.runs.flat()) * 1.12;
    C.dotGroups(ctx, w, h, d.runs, max, p.hot, d.ceiling);
    C.corners(ctx, w, h, p.line);
    const axis = document.getElementById("k-axis");
    if (axis && axis.children.length !== d.runs.length) {
      axis.innerHTML = d.runs
        .map((_, i) => `<span>retry ${i + 1}</span>`)
        .join("");
    }
  },
  (data) => {
    const median = (xs) => {
      const s = [...xs].sort((a, b) => a - b);
      return s[Math.floor(s.length / 2)];
    };
    const first = median(data.runs[0]);
    const last = data.runs[data.runs.length - 1];
    const ms = (v) => Math.round(v / 1000);
    put("k-first", `${ms(first)} ms`);
    put("k-last", `${ms(median(last))} ms`);
    put("k-spread", `${ms(Math.min(...last))}–${ms(Math.max(...last))} ms`);
    const jitter = val("k-jitter");
    const words = {
      0: "Rigid: every client waits exactly as long as the schedule says, so they all come back at the same millisecond.",
      1: "Full: the wait is uniform over the whole ceiling, which spreads clients furthest and can retry immediately.",
      2: "Equal: half the ceiling plus a draw over the other half, so there is still a floor under the wait.",
      3: "Decorrelated: drawn against the last wait rather than the attempt number, so it grows from where it landed.",
      4: "Spread: the ceiling plus or minus the fraction, which keeps every client inside a known band.",
    };
    tell("k", words[jitter]);
  },
);

/* --- 04 shedder ---------------------------------------------------------- */

const shedderBench = bench(
  "s",
  ["s-scope"],
  () => JSON.parse(call()(3, val("s-demand"), val("s-service"), 12000, 5)),
  (upto) => {
    const d = shedderBench.data;
    const { ctx, w, h } = C.fit(shedderBench.canvases[0]);
    const p = C.palette();
    C.grid(ctx, w, h, 4, p.line, 2);
    const max = Math.max(4, ...d.flying);
    // refusals sit in a strip along the bottom, in their own scale
    const strip = Math.round(h * 0.28);
    ctx.save();
    ctx.translate(0, h - strip);
    C.bars(ctx, w, strip, d.refused, Math.max(3, ...d.refused), p.hot, upto);
    ctx.restore();
    C.stepLine(ctx, w, h, d.flying, max, p.sig, upto);
    C.stepLine(ctx, w, h, d.cpu, 1000, p.ink, upto);
    C.corners(ctx, w, h, p.line);
  },
  (data, upto) => {
    const tail = Math.min(upto, data.flying.length);
    put("s-peak", String(Math.max(0, ...data.flying.slice(0, tail))));
    put("s-refused", String(data.refused.slice(0, tail).reduce((a, b) => a + b, 0)));
    put("s-cpu", `${data.cpu[tail - 1] || 0}‰`);
    const refused = data.refused.slice(0, tail).reduce((a, b) => a + b, 0);
    if (refused === 0) {
      tell("s", "Nothing refused. Either the server never got hot, or it was hot with a queue short enough to keep serving.");
    } else {
      tell("s", "The server got hot and the calls in flight went past what it has shown it can finish, so the shedder started turning work away.");
    }
  },
);

/* --- wiring -------------------------------------------------------------- */

function redrawAll() {
  for (const entry of benches.values()) {
    if (entry.data) {
      entry.report(entry.data, entry.upto);
      entry.draw(entry.upto);
    }
  }
}

function start() {
  if (!ready()) {
    if (status) {
      status.textContent = "engine not built — run: moon build src/examples/browser --target js";
      status.classList.add("is-off");
    }
    for (const input of document.querySelectorAll("input, select")) input.disabled = true;
    return;
  }
  if (status) status.textContent = "engine online — moonward 0.2.0 compiled to JavaScript";

  knob("b-interval", (v) => `${v} ms`, () => measure(breakerBench));
  knob("b-from", (v) => `${(v / 10).toFixed(1)} s`, () => measure(breakerBench));
  knob("b-len", (v) => `${(v / 10).toFixed(1)} s`, () => measure(breakerBench));
  knob("b-bp", (v) => `${v}%`, () => measure(breakerBench));

  knob("l-demand", (v) => `${v} /s`, () => measure(limiterBench));
  knob("l-quota", (v) => `${v} /s`, () => measure(limiterBench));
  knob("l-burst", (v) => String(v), () => measure(limiterBench));

  knob("k-base", (v) => `${v} ms`, () => measure(backoffBench));
  knob("k-factor", (v) => `${(v / 10).toFixed(1)}×`, () => measure(backoffBench));
  knob("k-cap", (v) => `${v} ms`, () => measure(backoffBench));
  knob("k-attempts", (v) => String(v), () => measure(backoffBench));
  const jitter = document.getElementById("k-jitter");
  if (jitter) jitter.addEventListener("change", () => measure(backoffBench));

  knob("s-demand", (v) => `${v} /s`, () => measure(shedderBench));
  knob("s-service", (v) => `${v} ms`, () => measure(shedderBench));

  const resize = () => redrawAll();
  window.addEventListener("resize", resize);
  C.onTheme(resize);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
