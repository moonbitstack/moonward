import { highlight } from "./highlight.js";

/* --- code ----------------------------------------------------------------- */

highlight();

for (const pre of document.querySelectorAll("pre[data-lang]")) {
  const bar = pre.parentElement?.querySelector(".screen__bar");
  if (!bar || bar.querySelector(".copy")) continue;
  const btn = document.createElement("button");
  btn.className = "copy";
  btn.type = "button";
  btn.textContent = "copy";
  btn.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(pre.textContent);
      btn.textContent = "copied";
    } catch {
      btn.textContent = "select";
    }
    window.setTimeout(() => (btn.textContent = "copy"), 1400);
  });
  bar.append(btn);
}

/* --- the hud frame -------------------------------------------------------- */

const gauge = document.querySelector("[data-gauge]");
const readout = document.querySelector("[data-hud-read]");

function hud() {
  const max = document.documentElement.scrollHeight - window.innerHeight;
  const p = max > 0 ? Math.min(1, window.scrollY / max) : 0;
  if (gauge) gauge.style.height = `${(p * 100).toFixed(2)}%`;
  if (readout) readout.textContent = String(Math.round(p * 100)).padStart(3, "0");
}

window.addEventListener("scroll", hud, { passive: true });
window.addEventListener("resize", hud);
hud();

/* --- which station is on screen ------------------------------------------- */

const stations = [...document.querySelectorAll("[data-station]")];
const links = new Map(
  [...document.querySelectorAll("[data-toc]")].map((a) => [a.hash.slice(1), a]),
);

if (stations.length && links.size) {
  const seen = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        for (const a of links.values()) a.removeAttribute("aria-current");
        const link = links.get(e.target.id);
        if (link) link.setAttribute("aria-current", "true");
      }
    },
    { rootMargin: "-20% 0px -70% 0px", threshold: 0 },
  );
  for (const s of stations) seen.observe(s);
}
