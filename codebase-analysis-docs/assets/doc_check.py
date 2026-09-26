#!/usr/bin/env python3
"""Consistency checks for codebase-analysis-docs/CODEBASE_KNOWLEDGE.md.

Run from anywhere:  python3 codebase-analysis-docs/assets/doc_check.py

Checks:
  * every in-document link (](#anchor)) resolves to a heading (GitHub anchor rules)
  * code fences are balanced
  * markdown tables keep a constant column count
  * every [[F:path#range#hash8]] anchor still matches sha256(path)[:8] in the working tree
Exit status is non-zero when any check fails; hash mismatches mean "re-verify that claim".
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
DOC = ROOT / "codebase-analysis-docs" / "CODEBASE_KNOWLEDGE.md"


def anchor(heading: str) -> str:
    a = re.sub(r"[^\w\- ]", "", heading.strip().lower())
    return a.replace(" ", "-")


def main() -> int:
    text = DOC.read_text(encoding="utf-8")
    lines = text.split("\n")
    failures = 0

    headings, inside = set(), False
    for line in lines:
        if line.startswith("```"):
            inside = not inside
        elif not inside and re.match(r"^#{1,6} ", line):
            headings.add(anchor(re.sub(r"^#+ ", "", line)))
    broken = [l for l in re.findall(r"\]\(#([^)]+)\)", text) if l not in headings]
    if broken:
        failures += 1
        print("Broken internal links:", broken)

    if sum(1 for l in lines if l.startswith("```")) % 2:
        failures += 1
        print("Unbalanced code fences")

    inside, table = False, []
    for i, line in enumerate(lines + [""], start=1):
        if line.startswith("```"):
            inside = not inside
        if not inside and line.lstrip().startswith("|"):
            cells = re.sub(r"`[^`]*`", "", line.strip())
            table.append((i, cells.count("|") - cells.count("\\|")))
            continue
        if table and len({n for _, n in table}) > 1:
            failures += 1
            print(f"Table starting at line {table[0][0]} has inconsistent column counts")
        table = []

    mismatches = 0
    for path, _rng, digest in sorted(set(re.findall(r"\[\[F:([^#\]]+)#([^#\]]+)#([0-9a-f]{8})\]\]", text))):
        target = ROOT / path
        if not target.exists():
            print(f"Anchor target missing: {path}")
            mismatches += 1
            continue
        current = hashlib.sha256(target.read_bytes()).hexdigest()[:8]
        if current != digest:
            print(f"Changed since documented: {path} (doc {digest}, now {current})")
            mismatches += 1
    if mismatches:
        failures += 1

    print("OK" if not failures else f"{failures} check(s) failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
