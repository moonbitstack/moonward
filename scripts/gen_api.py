#!/usr/bin/env python3
"""Generate docs/api.html from src/pkg.generated.mbti and the /// comments.

The interface file decides what is public; the sources supply the readable
signature (parameter names, labels, defaults) and the prose. Nothing is written
by hand into the page, so re-running this after a change is the whole job:

    python3 scripts/gen_api.py

The output is deterministic — no timestamps, no ordering that depends on the
filesystem — so `git diff --exit-code docs/api.html` is empty on a clean tree.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "docs" / "api.html"
MBTI = SRC / "pkg.generated.mbti"

# The order the page reads in: the two policies, then the pieces they are made
# of, then the ones that stand alone.
GROUPS: list[tuple[str, str, list[str]]] = [
    (
        "01",
        "The breaker",
        ["Sre", "Breaker", "Promise"],
    ),
    (
        "02",
        "Load shedding",
        ["Shed", "Shedder", "Ticket"],
    ),
    (
        "03",
        "Rate and quota",
        ["Bucket", "Sliding", "Period", "Quota"],
    ),
    (
        "04",
        "Concurrency",
        ["Gate"],
    ),
    (
        "05",
        "Retry",
        ["Backoff", "Jitter"],
    ),
    (
        "06",
        "Time",
        ["Deadline"],
    ),
    (
        "07",
        "Windows",
        ["Window", "Outcome", "Tally", "Total"],
    ),
]

DERIVED = {"equal", "not_equal", "to_repr", "default"}
TRAITS = {"equal": "Eq", "not_equal": "Eq", "to_repr": "Debug", "default": "Default"}

DECL_FN = re.compile(
    r"^(?:pub\s+)?(?:async\s+)?fn\s*(?:\[[^\]]*\]\s*)?([A-Za-z_][\w]*(?:::[A-Za-z_]\w*)?)\s*\("
)
DECL_STRUCT = re.compile(r"^(pub(?:\(all\))?\s+)?struct\s+([A-Za-z_]\w*)")
DECL_ENUM = re.compile(r"^(pub(?:\(all\))?\s+)?enum\s+([A-Za-z_]\w*)")
DECL_LET = re.compile(r"^pub\s+let\s+([a-z_]\w*)\s*:")
FIELD = re.compile(r"^(?:mut\s+)?([a-z_]\w*)\s*:\s*(.+?)\s*,?$")


# ---------------------------------------------------------------- sources --


def strip_doc_marker(line: str) -> str | None:
    line = line.strip()
    if not line.startswith("///"):
        return None
    text = line[3:]
    if text.startswith(" "):
        text = text[1:]
    return text


def join_doc(lines: list[str]) -> str:
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def parse_sources() -> tuple[dict[str, str], dict[str, dict[str, str]], dict[str, str]]:
    """Return (docs, field docs, signatures) keyed by name."""
    docs: dict[str, str] = {}
    fields: dict[str, dict[str, str]] = {}
    sigs: dict[str, str] = {}
    for path in sorted(SRC.glob("*.mbt")):
        lines = path.read_text(encoding="utf-8").split("\n")
        doc: list[str] = []
        struct: str | None = None
        depth = 0
        i = 0
        while i < len(lines):
            raw = lines[i]
            text = strip_doc_marker(raw)
            if text is not None:
                if text == "|":
                    doc = []
                else:
                    doc.append(text)
                i += 1
                continue
            s = raw.strip()
            if not s or s.startswith("//"):
                i += 1
                continue

            if struct and depth == 1 and FIELD.match(s):
                name = FIELD.match(s).group(1)
                if doc:
                    fields.setdefault(struct, {})[name] = join_doc(doc)
                doc = []
            else:
                m_fn = DECL_FN.match(s)
                m_st = DECL_STRUCT.match(s)
                m_en = DECL_ENUM.match(s)
                m_let = DECL_LET.match(s)
                if m_fn:
                    name = m_fn.group(1)
                    if doc:
                        docs[name] = join_doc(doc)
                    sigs[name] = read_signature(lines, i)
                    doc = []
                elif m_st or m_en:
                    name = (m_st or m_en).group(2)
                    if doc:
                        docs[name] = join_doc(doc)
                    struct = name
                    doc = []
                elif m_let:
                    name = m_let.group(1)
                    if doc:
                        docs[name] = join_doc(doc)
                    doc = []
                else:
                    doc = []

            depth += raw.count("{") - raw.count("}")
            if depth <= 0:
                depth = 0
                struct = None
            i += 1
    return docs, fields, sigs


def read_signature(lines: list[str], start: int) -> str:
    """Fold a declaration, and its parameter list, onto one line."""
    buf: list[str] = []
    depth = 0
    opened = False
    for raw in lines[start:]:
        s = raw.strip()
        for ch in s:
            if ch == "(":
                depth += 1
                opened = True
            elif ch == ")":
                depth -= 1
        buf.append(s)
        if opened and depth <= 0:
            break
    text = " ".join(buf)
    # everything past the closing parenthesis is the body
    end = text.find(")")
    if end != -1:
        rest = text[end + 1 :]
        ret = re.match(r"\s*->\s*([^{]+)", rest)
        text = text[: end + 1] + (f" -> {ret.group(1).strip()}" if ret else "")
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"\(\s+", "(", text)
    text = re.sub(r"\s+\)", ")", text)
    text = re.sub(r",\s*,", ",", text)
    text = re.sub(r",\s*\)", ")", text)
    return text.replace(", ", ", ").strip()


# ------------------------------------------------------------------- mbti --


class Item:
    def __init__(self, kind: str, name: str):
        self.kind = kind  # struct | enum | fn | value
        self.name = name
        self.signature = ""
        self.fields: list[tuple[str, str]] = []
        self.variants: list[str] = []
        self.methods: list["Item"] = []
        self.owner: str | None = None
        self.derived: list[str] = []
        self.opaque = False


def parse_mbti() -> tuple[list[Item], list[Item]]:
    types: list[Item] = []
    values: list[Item] = []
    fns: list[Item] = []
    section = ""
    current: Item | None = None
    for raw in MBTI.read_text(encoding="utf-8").split("\n"):
        s = raw.strip()
        if not s:
            continue
        if s.startswith("// "):
            section = s[3:].strip()
            current = None
            continue
        if section == "Values":
            m = re.match(r"pub let (\w+) : (.+)", s)
            if m:
                item = Item("value", m.group(1))
                item.signature = f"pub let {m.group(1)} : {m.group(2).strip()}"
                values.append(item)
            continue
        if section != "Types and methods":
            continue

        m = re.match(r"pub(\(all\))? (struct|enum) (\w+)(.*)", s)
        if m:
            current = Item(m.group(2), m.group(3))
            current.opaque = m.group(1) is None
            types.append(current)
            continue
        if s == "}":
            continue
        if s.startswith("pub fn"):
            rest = s[len("pub fn") :].strip()
            fm = re.match(r"(?:\[[^\]]*\]\s*)?(\w+)::(\w+)\(", rest)
            if fm:
                method = Item("fn", fm.group(2))
                method.owner = fm.group(1)
                fns.append(method)
            continue
        if current is not None:
            if current.kind == "struct":
                if current.opaque:
                    continue
                fm = re.match(r"(?:mut )?(\w+) : (.+)", s)
                if fm:
                    current.fields.append((fm.group(1), fm.group(2).strip()))
                continue
            if current.kind == "enum" and s != "// private fields":
                current.variants.append(s)

    by_name = {t.name: t for t in types}
    for fn in fns:
        owner = by_name.get(fn.owner)
        if owner is None:
            continue
        if fn.name in DERIVED:
            owner.derived.append(fn.name)
        else:
            owner.methods.append(fn)
    return types, values


# ------------------------------------------------------------------ render --


def inline(text: str) -> str:
    out = html.escape(" ".join(text.split()), quote=False)
    # [`Name`] and [`Name::method`] are references into this page
    out = re.sub(
        r"\[`([A-Za-z_]\w*(?:::[a-z_]\w*)?)`\]",
        lambda m: f'<a class="ref" href="#{m.group(1)}"><code>{m.group(1)}</code></a>',
        out,
    )
    out = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', out
    )
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    return out


def render_md(text: str) -> str:
    """A small subset: paragraphs, lists, tables, fences, `# ` headings."""
    lines = text.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        s = line.strip()
        if not s:
            i += 1
            continue
        if s.startswith("```"):
            i += 1
            block = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                block.append(lines[i])
                i += 1
            i += 1
            out.append("<pre class=\"snippet\">" + html.escape("\n".join(block)) + "</pre>")
            continue
        if s.startswith("# "):
            # Parameter sections are rendered as a table elsewhere; other
            # headings become a label above their text.
            out.append(f'<p class="mdlabel">{inline(s[2:])}</p>')
            i += 1
            continue
        if s.startswith("|") and i + 1 < len(lines) and set(lines[i + 1].strip()) <= set("|:- "):
            head = [c.strip() for c in s.strip("|").split("|")]
            i += 2
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            body = "".join(
                "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in rows
            )
            out.append(
                '<table class="mtable"><thead><tr>'
                + "".join(f"<th>{inline(c)}</th>" for c in head)
                + "</tr></thead><tbody>"
                + body
                + "</tbody></table>"
            )
            continue
        if s.startswith("- "):
            items = []
            while i < len(lines) and lines[i].strip().startswith("- "):
                items.append(f"<li>{inline(lines[i].strip()[2:])}</li>")
                i += 1
            out.append("<ul>" + "".join(items) + "</ul>")
            continue
        para = []
        while i < len(lines):
            cur = lines[i].strip()
            if not cur or cur.startswith(("- ", "#", "|", "```")):
                break
            para.append(cur)
            i += 1
        out.append("<p>" + inline(" ".join(para)) + "</p>")
    return "\n".join(out)


def split_params(doc: str) -> tuple[str, dict[str, str]]:
    """Take the `# Parameters` block out of a doc comment."""
    keep: list[str] = []
    params: dict[str, str] = {}
    in_params = False
    for line in doc.split("\n"):
        s = line.strip()
        if s.startswith("# Parameters"):
            in_params = True
            continue
        if in_params:
            m = re.match(r"-\s*`(\w+)`\s*:\s*(.*)", s)
            if m:
                params[m.group(1)] = m.group(2)
                continue
            if not s:
                continue
            in_params = False
        keep.append(line)
    return "\n".join(keep), params


def parse_sig_params(sig: str) -> list[tuple[str, str, str]]:
    """(name, type, default) for every parameter but the receiver."""
    open_paren = sig.find("(")
    close = sig.rfind(")")
    if open_paren == -1 or close == -1:
        return []
    inner = sig[open_paren + 1 : close]
    parts, depth, buf = [], 0, ""
    for ch in inner:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(buf)
            buf = ""
        else:
            buf += ch
    if buf.strip():
        parts.append(buf)
    out = []
    for part in parts:
        p = part.strip()
        if not p:
            continue
        name_part, _, rest = p.partition(":")
        name = name_part.strip()
        if name in ("self", "_"):
            continue
        default = ""
        if "=" in rest:
            rest, _, default = rest.partition("=")
        typ = rest.strip().rstrip(")").strip()
        out.append((name, typ, default.strip()))
    return out


def sig_fragment(sig: str) -> str:
    """One signature line, coloured like the code blocks."""
    sig = sig.replace("?", "?").strip()
    out = html.escape(sig, quote=False)
    out = re.sub(r"\b(pub|fn|struct|enum|let|mut)\b", r'<span class="kw">\1</span>', out)
    out = re.sub(r"(@[\w.]+)", r'<span class="ty">\1</span>', out)
    out = re.sub(r"(\b[A-Z]\w*)", r'<span class="ty">\1</span>', out)
    out = re.sub(r"(\b\d[\d_.]*)\b", r'<span class="nu">\1</span>', out)
    # break long signatures at parameter boundaries rather than at random
    return out.replace(", ", ",&#8203; ")


def chip(text: str, kind: str = "") -> str:
    cls = "chip" + (f" chip--{kind}" if kind else "")
    return f'<span class="{cls}">{html.escape(text)}</span>'


def render_params(sig: str, docs: dict[str, str]) -> str:
    params = parse_sig_params(sig)
    if not params:
        return ""
    rows = []
    seen = set()
    for name, typ, default in params:
        label = name.rstrip("~")
        seen.add(label)
        doc = docs.get(label, "")
        default_cell = (
            f'<code class="dflt">{html.escape(default)}</code>' if default else "—"
        )
        rows.append(
            "<tr>"
            f'<td class="pname"><code>{html.escape(label)}</code>'
            + (f'<i class="lab">~</i>' if name.endswith("~") else "")
            + "</td>"
            f'<td class="ptype"><code>{html.escape(typ)}</code></td>'
            f'<td class="pdef">{default_cell}</td>'
            f'<td class="pdoc">{inline(doc) if doc else ""}</td>'
            "</tr>"
        )
    # parameters documented but absent from the signature are a mistake; keep
    # them visible rather than silently dropping the prose.
    for name, doc in docs.items():
        if name not in seen:
            rows.append(
                "<tr>"
                f'<td class="pname"><code>{html.escape(name)}</code></td>'
                '<td class="ptype">—</td><td class="pdef">—</td>'
                f'<td class="pdoc">{inline(doc)}</td></tr>'
            )
    return (
        '<table class="params"><thead><tr>'
        "<th>parameter</th><th>type</th><th>default</th><th>what it is</th>"
        "</tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
    )


def render_fn(item: Item, docs: dict[str, str], sigs: dict[str, str], owner: str) -> str:
    key = f"{owner}::{item.name}"
    sig = sigs.get(key, f"{owner}::{item.name}(… ) -> ?")
    doc = docs.get(key, "")
    prose, params = split_params(doc)
    anchor = key.replace("::", "-")
    return f"""
<article class="fn" id="{anchor}" data-name="{html.escape(key.lower())}">
  <div class="fn__sig"><code>{sig_fragment(sig)}</code></div>
  {f'<div class="fn__doc">{render_md(prose)}</div>' if prose.strip() else ''}
  {render_params(sig, params)}
</article>"""


def render_type(item: Item, docs: dict[str, str], sigs: dict[str, str], fdocs: dict) -> str:
    name = item.name
    doc = docs.get(name, "")
    prose, _ = split_params(doc)
    kind = "struct" if item.kind == "struct" else "enum"
    parts = [f'<article class="api" id="{name}" data-name="{html.escape(name.lower())}">']
    derived = ""
    if item.derived:
        names = sorted({TRAITS.get(d, d) for d in item.derived})
        derived = f'<span class="api__derived">derives {", ".join(names)}</span>'
    parts.append(
        f"""<header class="api__head">
  <h3 class="api__name">{html.escape(name)}</h3>
  {chip(kind, "kind")}
  {derived}
</header>"""
    )
    if prose.strip():
        parts.append(f'<div class="api__doc">{render_md(prose)}</div>')

    if item.fields:
        rows = []
        for field_name, field_type in item.fields:
            text = fdocs.get(name, {}).get(field_name, "")
            rows.append(
                "<tr>"
                f'<td class="pname"><code>{html.escape(field_name)}</code></td>'
                f'<td class="ptype"><code>{html.escape(field_type)}</code></td>'
                f'<td class="pdoc">{inline(text)}</td>'
                "</tr>"
            )
        parts.append(
            '<table class="params"><thead><tr>'
            "<th>field</th><th>type</th><th>what it is</th>"
            "</tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
        )
    elif item.kind == "struct":
        parts.append(
            '<p class="api__note">Held by the caller. Its fields are private; '
            "the methods below are the way in.</p>"
        )

    if item.variants:
        items = "".join(
            f'<li><code>{html.escape(v)}</code></li>' for v in item.variants
        )
        parts.append(f'<ul class="variants">{items}</ul>')

    if item.methods:
        parts.append('<div class="fns">')
        for method in item.methods:
            parts.append(render_fn(method, docs, sigs, name))
        parts.append("</div>")
    parts.append("</article>")
    return "\n".join(parts)


def render_value(item: Item, docs: dict[str, str]) -> str:
    doc = docs.get(item.name, "")
    return f"""
<article class="api api--value" id="{item.name}" data-name="{html.escape(item.name.lower())}">
  <header class="api__head">
    <h3 class="api__name">{html.escape(item.name)}</h3>
    {chip("preset", "kind")}
    <span class="api__derived">{html.escape(item.signature.replace("pub let ", "let "))}</span>
  </header>
  <div class="api__doc">{render_md(doc)}</div>
</article>"""


def build() -> str:
    types, values = parse_mbti()
    docs, fdocs, sigs = parse_sources()
    by_name = {t.name: t for t in types}
    value_by_name = {v.name: v for v in values}

    placed = set()
    body: list[str] = []
    index: list[str] = []

    for number, title, names in GROUPS:
        present = [n for n in names if n in by_name]
        if not present:
            continue
        placed.update(present)
        index.append(
            f'<li><a href="#g{number}"><i>{number}</i>{html.escape(title)}</a>'
            '<ul class="idx__types">'
            + "".join(f'<li><a href="#{n}">{html.escape(n)}</a></li>' for n in present)
            + "</ul></li>"
        )
        body.append(
            f'<section class="group" id="g{number}">'
            f'<h2 class="group__t"><i>{number}</i>{html.escape(title)}</h2>'
        )
        for n in present:
            body.append(render_type(by_name[n], docs, sigs, fdocs))
        body.append("</section>")

    # presets
    if value_by_name:
        index.append(
            '<li><a href="#gvalues"><i>08</i>Presets</a><ul class="idx__types">'
            + "".join(f'<li><a href="#{n}">{html.escape(n)}</a></li>' for n in value_by_name)
            + "</ul></li>"
        )
        body.append(
            '<section class="group" id="gvalues">'
            '<h2 class="group__t"><i>08</i>Presets</h2>'
        )
        for name in ["sre", "shed", "backoff"]:
            if name in value_by_name:
                body.append(render_value(value_by_name[name], docs))
        body.append("</section>")

    leftovers = [t for t in types if t.name not in placed]
    if leftovers:
        body.append(
            '<section class="group" id="grest"><h2 class="group__t"><i>09</i>Also public</h2>'
        )
        for t in leftovers:
            body.append(render_type(t, docs, sigs, fdocs))
        body.append("</section>")

    return TEMPLATE.replace("{{INDEX}}", "\n".join(index)).replace(
        "{{BODY}}", "\n".join(body)
    )


TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>API reference — moonward</title>
<meta name="description" content="Every public type, method and preset in moonward, with parameters, defaults and what each one answers.">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Big+Shoulders+Display:wght@500;700;800&family=Archivo:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="assets/site.css">
<link rel="stylesheet" href="assets/doc.css">
</head>
<body>

<div class="hud" aria-hidden="true">
  <i class="hud__c hud__c--bl"></i>
  <i class="hud__c hud__c--br"></i>
  <div class="hud__gauge"><i data-gauge></i></div>
  <div class="hud__read mono" data-hud-read>000</div>
</div>

<nav class="rail">
  <div class="rail__in">
    <a class="rail__mark" href="index.html">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true">
        <path d="M4 20V7l8 9 8-9v13"/><path d="M4 4h16" opacity=".45"/>
      </svg>
      <span>moonward</span>
    </a>
    <div class="rail__ch">
      <a href="guide.html"><b>01</b> Guide</a>
      <a href="api.html" aria-current="page"><b>02</b> API</a>
      <a href="bay.html"><b>03</b> Bay</a>
    </div>
    <a class="rail__git" href="https://github.com/moonbitstack/moonward" aria-label="Repository on GitHub">
      <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.4 7.4 0 0 1 2-.27c.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A7.995 7.995 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>
    </a>
    <span class="rail__ver">v0.2.0</span>
  </div>
</nav>

<header class="doc-head shell api-head">
  <div class="doc-head__meta">
    <span class="tag">Reference</span>
    <span class="tag">one package</span>
    <span class="tag">generated</span>
  </div>
  <h1 class="doc-head__title">API<br><em>reference</em></h1>
  <p class="doc-head__lede">Every public type, method and preset in <code>moonbitstack/moonward</code>. A parameter written <code>name~</code> is labelled with a default: pass it as <code>name=value</code> or leave it out.</p>
  <div class="api-search">
    <input id="api-filter" type="search" placeholder="filter — breaker, jitter, window…" autocomplete="off" aria-label="Filter the reference">
    <span class="api-search__count mono" id="api-count"></span>
  </div>
</header>

<div class="hazard"></div>

<div class="doc shell api-doc">
  <aside class="toc api-index" aria-label="Groups">
    <div class="toc__in">
      <p class="toc__t">Groups</p>
      <ul class="idx">
{{INDEX}}
      </ul>
    </div>
  </aside>

  <main class="doc__main" id="api-main">
{{BODY}}
  </main>
</div>

<footer class="foot shell">
  <span>moonward 0.2.0</span>
  <span>Apache-2.0</span>
  <a href="https://github.com/moonbitstack/moonward">GitHub</a>
  <a href="https://mooncakes.io/docs/moonbitstack/moonward">mooncakes</a>
  <span class="spacer"></span>
  <a href="index.html">Home</a>
  <a href="guide.html">Guide</a>
  <a href="bay.html">Bay</a>
</footer>

<script type="module" src="assets/site.js"></script>
<script type="module" src="assets/api.js"></script>
</body>
</html>
"""


def main() -> int:
    if not MBTI.exists():
        print(f"missing {MBTI}", file=sys.stderr)
        return 1
    OUT.write_text(build(), encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
