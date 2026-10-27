// A small MoonBit highlighter for the code blocks on this site. The blocks stay
// plain text in the HTML, so what is written is exactly what compiles.

const KEYWORDS =
  "let mut fn for in match if else while loop guard try catch raise pub priv struct enum type impl derive extern async is not and or";
const LITERALS = "true false Some None";

const escape = (s) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const pattern = new RegExp(
  [
    "(\\/\\/[^\\n]*)", // comment
    '("(?:[^"\\\\\\n]|\\\\.)*")', // string
    "(@[A-Za-z_][\\w.]*)", // package reference
    "\\b(\\d[\\d_]*(?:\\.\\d+)?[LlFfDd]?)\\b", // number
    "\\b(" + KEYWORDS.split(" ").join("|") + ")\\b",
    "\\b(" + LITERALS.split(" ").join("|") + ")\\b",
    "\\b([A-Z][A-Za-z0-9_]*)\\b", // type or variant
    "\\b([a-z_][\\w]*)(?=\\s*\\()", // call
  ].join("|"),
  "g",
);

const CLASSES = ["cm", "st", "ty", "nu", "kw", "kw", "ty", "cal"];

export function highlight(root = document) {
  for (const pre of root.querySelectorAll("pre[data-lang]")) {
    const text = pre.textContent;
    let out = "";
    let last = 0;
    for (const m of text.matchAll(pattern)) {
      out += escape(text.slice(last, m.index));
      const group = m.slice(1).findIndex((g) => g !== undefined);
      const cls = CLASSES[group] ?? "";
      out += cls ? `<span class="${cls}">${escape(m[0])}</span>` : escape(m[0]);
      last = m.index + m[0].length;
    }
    out += escape(text.slice(last));
    pre.innerHTML = out;
  }
}
