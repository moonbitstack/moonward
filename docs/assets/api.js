// Filter the reference: type the name of a type, a method or a parameter and
// everything that does not match goes away. No index rebuild, no fetch.

const input = document.getElementById("api-filter");
const count = document.getElementById("api-count");
const main = document.getElementById("api-main");
const cards = [...main.querySelectorAll(".api, .fn")];
const groups = [...main.querySelectorAll(".group")];

const total = count ? cards.length : 0;

function apply(query) {
  const q = query.trim().toLowerCase();
  let shown = 0;
  for (const card of cards) {
    const hay = card.dataset.name + " " + card.textContent.toLowerCase();
    const hit = !q || hay.includes(q);
    card.classList.toggle("is-hidden", !hit);
    if (hit) shown += 1;
  }
  for (const group of groups) {
    const any = group.querySelector(".api:not(.is-hidden), .fn:not(.is-hidden)");
    group.classList.toggle("is-empty", !any);
  }
  if (count) {
    count.textContent = q ? `${shown} / ${total}` : `${total} entries`;
  }
}

if (input) {
  input.addEventListener("input", () => apply(input.value));
  input.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      input.value = "";
      apply("");
    }
  });
  apply("");
}
