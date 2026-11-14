#!/usr/bin/env python3
"""Break one line at a time and record which tests notice.

This is a check on the suite, not part of the library: every mutation is applied
to a copy of the sources, `moon test` is run, and the sources are put back. The
output is the table the delivery note quotes.

    python3 scripts/check_mutations.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

# (file, what it should say, what it is changed to, and what the change is)
MUTATIONS: list[tuple[str, str, str, str]] = [
    (
        "breaker.mbt",
        "let w = k - (k - floor) * h.failing.to_double() / size",
        "let w = k + (k - floor) * h.failing.to_double() / size",
        "the weight of a success grows as buckets fail instead of decaying",
    ),
    (
        "shed.mbt",
        "if self.average > cap && self.flying.to_double() > cap {",
        "if self.average > cap || self.flying.to_double() > cap {",
        "either reading over capacity counts as full, instead of both",
    ),
    (
        "limit.mbt",
        "    if tokens > self.burst {\n      tokens = self.burst\n    }",
        "    if tokens > self.burst + 1.0 {\n      tokens = self.burst\n    }",
        "a bucket banks a token over its burst",
    ),
    (
        "limit.mbt",
        "self.stamps.retain(stamp => stamp > cut)",
        "self.stamps.retain(stamp => stamp >= cut)",
        "a window keeps the event on its own boundary",
    ),
    (
        "limit.mbt",
        "None if self.align => now - (now % self.period + self.period) % self.period",
        "None if self.align => now",
        "an aligned period opens where the first event lands",
    ),
    (
        "retry.mbt",
        "      let scale = 1.0 - f + 2.0 * f * clamp(random)",
        "      let scale = 1.0 - f + f * clamp(random)",
        "spread holds the wait under the ceiling instead of around it",
    ),
    (
        "deadline.mbt",
        "self.budget > 0L && now - self.start >= self.budget",
        "self.budget > 0L && now - self.start > self.budget",
        "a deadline expires a nanosecond late",
    ),
    (
        "adapt.mbt",
        "  } else if queued <= r.threshold * log {",
        "  } else if queued < r.threshold * log {",
        "vegas drops the case where the queue is exactly the threshold",
    ),
    (
        "window.mbt",
        "  let first = (self.head + span + 1) % size",
        "  let first = (self.head + span) % size",
        "a reading starts at the bucket that is still filling",
    ),
    (
        "limit.mbt",
        "    Some(start) if now - start >= self.period => { start: None, used: 0, }",
        "    Some(start) if now - start > self.period => { start: None, used: 0, }",
        "a fixed period closes a nanosecond late",
    ),
    (
        "adapt.mbt",
        "      est * (1.0 - r.smoothing) + r.smoothing * next,\n    )",
        "      est * r.smoothing + (1.0 - r.smoothing) * next,\n    )",
        "the first gradient rule smooths the wrong way round",
    ),
    (
        "compose.mbt",
        "        self.links[j].release(now)\n      }\n      return false",
        "        ignore(self.links[j])\n      }\n      return false",
        "a chain keeps what it took from the limiters before a refusal",
    ),
    (
        "compose.mbt",
        "      self.entries.remove(key)\n      self.entries[key] = limiter",
        "      self.entries[key] = limiter",
        "a partition is dropped by first use rather than last use",
    ),
]


def run() -> tuple[int, list[str]]:
    out = subprocess.run(
        ["moon", "test", "--target", "wasm-gc"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    text = out.stdout + out.stderr
    failed = sorted({line.split('("')[1].split('")')[0] for line in text.splitlines() if '") failed' in line})
    total = [line for line in text.splitlines() if line.startswith("Total tests:")]
    if not total:
        # A mutation that does not build says nothing about the tests.
        return -1, ["the mutated sources did not build"]
    count = int(total[-1].split("failed:")[1].split(".")[0].strip())
    return count, failed


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        backup = Path(tmp) / "src"
        shutil.copytree(SRC, backup)
        clean_count, clean_failed = run()
        if clean_failed:
            print("the tree is not green before the mutations:", clean_failed)
            return 1
        print(f"baseline: {clean_count} failures\n")
        rows = []
        for name, old, new, what in MUTATIONS:
            path = SRC / name
            text = path.read_text(encoding="utf-8")
            if old not in text:
                print(f"!! {name}: the line to break is not there")
                return 1
            path.write_text(text.replace(old, new, 1), encoding="utf-8")
            count, failed = run()
            shutil.copy2(backup / name, path)
            rows.append((name, what, count, failed))
            print(f"{name}: {what}\n  -> {count} failed: {', '.join(failed) or 'NOTHING'}\n")
    print("\n| file | break | tests that went red |")
    print("|:--|:--|:--|")
    for name, what, count, failed in rows:
        print(f"| `{name}` | {what} | {count}: {', '.join(f'`{f}`' for f in failed) or '**none**'} |")
    unseen = [what for _, what, count, _ in rows if count <= 0]
    for what in unseen:
        print(f"no test noticed: {what}")
    return 1 if unseen else 0


if __name__ == "__main__":
    sys.exit(main())
