#!/usr/bin/env python3
"""Put the module's own version on the pages, so no page carries a stale one.

`moon.mod` is the only place a release number is written down. The reference page
takes it from there when it is generated; this script does the same for the pages
that are written by hand, and is run by the docs workflow before the site is
published, with `git diff --exit-code` behind it:

    python3 scripts/sync_version.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"


def version() -> str:
    text = (ROOT / "moon.mod").read_text(encoding="utf-8")
    return re.search(r'version\s*=\s*"([^"]+)"', text).group(1)


def main() -> int:
    v = version()
    changed = []
    for page in sorted(DOCS.glob("*.html")):
        text = page.read_text(encoding="utf-8")
        out = re.sub(r'(<span class="rail__ver">v)[^<]*(</span>)', rf"\g<1>{v}\g<2>", text)
        out = re.sub(r"(<span>moonward )[^<]*(</span>)", rf"\g<1>{v}\g<2>", out)
        out = re.sub(
            r"(moon add moonbitstack/moonward@)[^\s<]*", rf"\g<1>{v}", out
        )
        if out != text:
            page.write_text(out, encoding="utf-8", newline="\n")
            changed.append(page.name)
    print(f"version {v}: {', '.join(changed) if changed else 'every page already agrees'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
