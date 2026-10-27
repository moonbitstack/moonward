// Canvas drawing for the panels. Everything is a hard edge: no rounded caps, no
// curves, no gradients except the hatch. One device pixel is one line.

const root = document.documentElement;

export function palette() {
  const read = (name) =>
    getComputedStyle(root).getPropertyValue(name).trim() || "#888";
  return {
    hot: read("--hot"),
    sig: read("--sig"),
    ink: read("--ink"),
    dim: read("--dim"),
    faint: read("--faint"),
    line: read("--line"),
    plate: read("--plate"),
    screen: read("--screen"),
    amber: read("--amber"),
  };
}

/** Size a canvas to its CSS box and return a snapped context. */
export function fit(canvas) {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const rect = canvas.getBoundingClientRect();
  const w = Math.max(1, Math.round(rect.width));
  const h = Math.max(1, Math.round(rect.height));
  if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
    canvas.width = w * dpr;
    canvas.height = h * dpr;
  }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  return { ctx, w, h };
}

/** Horizontal rules with a tick on the left edge. */
export function grid(ctx, w, h, steps, color, pad = 0) {
  ctx.save();
  ctx.strokeStyle = color;
  ctx.globalAlpha = 0.35;
  ctx.lineWidth = 1;
  for (let i = 0; i <= steps; i++) {
    const y = Math.round(pad + ((h - pad * 2) * i) / steps) + 0.5;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
  ctx.restore();
}

/** A vertical band, for a window in time. */
export function band(ctx, w, h, from, to, color) {
  const x = Math.round(from * w);
  const x2 = Math.round(to * w);
  ctx.save();
  ctx.fillStyle = color;
  ctx.globalAlpha = 0.08;
  ctx.fillRect(x, 0, x2 - x, h);
  ctx.globalAlpha = 0.5;
  ctx.strokeStyle = color;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(x + 0.5, 0);
  ctx.lineTo(x + 0.5, h);
  ctx.moveTo(x2 - 0.5, 0);
  ctx.lineTo(x2 - 0.5, h);
  ctx.stroke();
  ctx.restore();
}

/** Columns: heights in the same unit as `max`, one per slot. */
export function bars(ctx, w, h, values, max, color, upto = values.length) {
  const n = values.length;
  if (!n) return;
  const slot = w / n;
  const bw = Math.max(1, Math.floor(slot) - (slot > 6 ? 1 : 0));
  ctx.save();
  ctx.fillStyle = color;
  for (let i = 0; i < Math.min(upto, n); i++) {
    const v = values[i];
    if (!v) continue;
    const bh = Math.max(1, Math.round((v / max) * h));
    ctx.globalAlpha = 0.9;
    ctx.fillRect(Math.floor(i * slot), h - bh, bw, bh);
  }
  ctx.restore();
}

/** A step line: the shape a decision makes, not a curve. */
export function stepLine(ctx, w, h, values, max, color, upto = values.length) {
  const n = values.length;
  if (n < 2) return;
  const slot = w / n;
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = 1.5;
  ctx.lineJoin = "miter";
  ctx.beginPath();
  const limit = Math.min(upto, n);
  for (let i = 0; i < limit; i++) {
    const y = Math.round(h - (values[i] / max) * h) + 0.5;
    const x = Math.round(i * slot) + 0.5;
    if (i === 0) ctx.moveTo(x, y);
    else {
      ctx.lineTo(x, y);
    }
    if (i < limit - 1) ctx.lineTo(Math.round((i + 1) * slot) + 0.5, y);
  }
  ctx.stroke();
  ctx.restore();
}

/** Filled area under a step line, for a count rather than a rate. */
export function area(ctx, w, h, values, max, color, upto = values.length) {
  const n = values.length;
  if (n < 2) return;
  const slot = w / n;
  const limit = Math.min(upto, n);
  ctx.save();
  ctx.fillStyle = color;
  ctx.globalAlpha = 0.22;
  ctx.beginPath();
  ctx.moveTo(0, h);
  for (let i = 0; i < limit; i++) {
    const y = Math.round(h - (values[i] / max) * h);
    ctx.lineTo(Math.round(i * slot), y);
    if (i < limit - 1) ctx.lineTo(Math.round((i + 1) * slot), y);
  }
  ctx.lineTo(Math.round((limit - 1) * slot), h);
  ctx.closePath();
  ctx.fill();
  ctx.restore();
  stepLine(ctx, w, h, values, max, color, limit);
}

/** One column of short strokes per group, a dot per sample. */
export function dotGroups(ctx, w, h, groups, max, color, ceiling) {
  const n = groups.length;
  if (!n) return;
  const slot = w / n;
  ctx.save();
  for (let g = 0; g < n; g++) {
    const cx = Math.round(slot * (g + 0.5));
    const vals = groups[g];
    ctx.globalAlpha = 0.75;
    ctx.fillStyle = color;
    for (const v of vals) {
      const y = Math.round(h - (v / max) * h);
      ctx.fillRect(cx - 7, y, 14, 1);
      ctx.globalAlpha = 0.25;
      ctx.fillRect(cx - 7, y + 1, 14, 1);
      ctx.globalAlpha = 0.75;
    }
    if (ceiling && ceiling[g] != null) {
      const cy = Math.round(h - (ceiling[g] / max) * h);
      ctx.globalAlpha = 1;
      ctx.strokeStyle = color;
      ctx.setLineDash([3, 3]);
      ctx.beginPath();
      ctx.moveTo(cx - Math.min(22, slot / 2 - 4), cy + 0.5);
      ctx.lineTo(cx + Math.min(22, slot / 2 - 4), cy + 0.5);
      ctx.stroke();
      ctx.setLineDash([]);
    }
  }
  ctx.restore();
}

/** Hollow boxes in a row, filled up to `used`. A gauge, not a chart. */
export function cells(ctx, w, h, count, used, color, dim) {
  const gap = 2;
  const cw = (w - gap * (count - 1)) / count;
  ctx.save();
  for (let i = 0; i < count; i++) {
    const x = i * (cw + gap);
    if (i < used) {
      ctx.fillStyle = color;
      ctx.fillRect(Math.round(x), 0, Math.max(1, Math.round(cw)), h);
    } else {
      ctx.strokeStyle = dim;
      ctx.lineWidth = 1;
      ctx.strokeRect(
        Math.round(x) + 0.5,
        0.5,
        Math.max(1, Math.round(cw)),
        h - 1,
      );
    }
  }
  ctx.restore();
}

/** The four corner ticks that frame every scope. */
export function corners(ctx, w, h, color) {
  const s = 7;
  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(0, s);
  ctx.lineTo(0, 0);
  ctx.lineTo(s, 0);
  ctx.moveTo(w - s, 0);
  ctx.lineTo(w, 0);
  ctx.lineTo(w, s);
  ctx.moveTo(w, h - s);
  ctx.lineTo(w, h);
  ctx.lineTo(w - s, h);
  ctx.moveTo(s, h);
  ctx.lineTo(0, h);
  ctx.lineTo(0, h - s);
  ctx.stroke();
  ctx.restore();
}

/** A caption inside the drawing area, top-left, mono. */
export function note(ctx, text, color, x = 8, y = 13) {
  ctx.save();
  ctx.fillStyle = color;
  ctx.font = '500 9px "IBM Plex Mono", monospace';
  ctx.letterSpacing = "1px";
  ctx.fillText(text, x, y);
  ctx.restore();
}

export function onTheme(fn) {
  const mq = window.matchMedia("(prefers-color-scheme: dark)");
  mq.addEventListener("change", fn);
  return fn;
}
