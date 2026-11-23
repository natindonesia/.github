#!/usr/bin/env python3
"""Repoint a QA report's local file references at their published URLs.

The report is written by an agent against a directory on disk, so its links look
like `./after-home.png`, `output/after-home.png`, or an absolute path. This maps
each one to the object that publish.sh just uploaded and writes a second copy of
the document with public URLs, which is what gets posted.

Anything that cannot be resolved is an error: a report that points at a capture
nobody uploaded renders as a broken image, and a broken image where evidence
should be is worse than a missing one.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

MAPPING = Path(os.environ["MAPPING"])
REPORT = Path(os.environ["REPORT_PATH"])
ROOT = Path(os.environ["EVIDENCE_ROOT"]).resolve()
RENDERED = Path(os.environ["RENDERED"])

# ![alt](target) and [text](target), target optionally carrying a "title".
MARKDOWN = re.compile(r"(!?\[[^\]]*\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")
# <img src="target"> and src='target'
HTML_IMG = re.compile(r"""(<img\b[^>]*?\bsrc\s*=\s*)(["'])([^"']+)(\2)""", re.IGNORECASE)
ABSOLUTE = re.compile(r"^[a-z][a-z0-9+.-]*:", re.IGNORECASE)


def load_mapping() -> dict[str, str]:
    urls: dict[str, str] = {}
    for line in MAPPING.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rel, url = line.split("\t", 1)
        urls[rel] = url
    return urls


def resolve(target: str, urls: dict[str, str]) -> str | None:
    """Map a link as written to an uploaded object, or None."""
    if ABSOLUTE.match(target) or target.startswith("#"):
        return None

    candidate = target.split("?")[0].split("#")[0].strip()
    # An absolute path inside the evidence directory is what the workflow tells
    # the agent to use; make it relative again.
    prefix = str(ROOT)
    if candidate.startswith(prefix):
        candidate = candidate[len(prefix):]
    while candidate.startswith("./"):
        candidate = candidate[2:]
    candidate = candidate.lstrip("/")

    for key in (candidate, f"output/{candidate}", f"evidence/{candidate}"):
        if key in urls:
            return urls[key]

    # Last resort: the file name alone, which is how an agent usually writes a
    # sibling capture. Ambiguity is refused rather than guessed.
    hits = [u for rel, u in urls.items() if Path(rel).name == Path(candidate).name]
    return hits[0] if len(hits) == 1 else None


def main() -> int:
    urls = load_mapping()
    doc = REPORT.read_text(encoding="utf-8", errors="replace")
    missing: list[str] = []
    referenced: set[str] = set()

    def substitute(target: str) -> str | None:
        if ABSOLUTE.match(target) or target.startswith("#"):
            return target
        url = resolve(target, urls)
        if url is None:
            missing.append(target)
            return None
        referenced.add(url)
        return url

    def on_markdown(match: re.Match[str]) -> str:
        head, target, tail = match.group(1), match.group(2), match.group(3)
        url = substitute(target)
        return match.group(0) if url is None else f"{head}{url}{tail}"

    def on_html(match: re.Match[str]) -> str:
        head, quote, target, close = match.groups()
        url = substitute(target)
        return match.group(0) if url is None else f"{head}{quote}{url}{close}"

    rendered = HTML_IMG.sub(on_html, MARKDOWN.sub(on_markdown, doc))

    if missing:
        listed = ", ".join(sorted(set(missing)))
        print(
            f"::error title=Broken evidence links::the report references files that"
            f" were not captured: {listed}",
            file=sys.stderr,
        )
        return 1

    unreferenced = sorted(set(urls.values()) - referenced)
    if unreferenced:
        print("Uploaded but not shown in the report: " + ", ".join(unreferenced))

    RENDERED.write_text(rendered, encoding="utf-8")
    print(f"rendered {RENDERED} ({len(urls)} object(s) available)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
