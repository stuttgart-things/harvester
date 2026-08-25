#!/usr/bin/env python3
"""Build the interactive D3 page for GitHub Pages from inventory.yaml.

The result is a single self-contained HTML file: the d3 bundle is inlined so
the page runs without a CDN and without a further build step - over file://
exactly as it does behind GitHub Pages.

Usage: python3 build_html.py [--in inventory.yaml] [--out site/index.html]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).parent


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", default=str(HERE / "inventory.yaml"))
    ap.add_argument("--out", dest="out", default=str(HERE / "site/index.html"))
    ap.add_argument("--template", default=str(HERE / "template.html"))
    ap.add_argument("--d3", default=str(HERE / "vendor/d3.min.js"))
    args = ap.parse_args()

    d3 = Path(args.d3)
    if not d3.is_file():
        print(f"ERROR: {d3} is missing - run 'make d3-install' first.", file=sys.stderr)
        return 1

    data = yaml.safe_load(Path(args.src).read_text(encoding="utf-8")) or {}
    data.setdefault("site", {})
    data.setdefault("networks", [])
    data.setdefault("hosts", [])

    body = Path(args.template).read_text(encoding="utf-8")
    # The bundle contains no "</script>", which would otherwise need escaping.
    body = body.replace("/*__D3__*/", d3.read_text(encoding="utf-8"))
    body = body.replace("/*__DATA__*/", json.dumps(data, ensure_ascii=False))

    # template.html is a fragment. The served page needs a complete document -
    # above all <meta charset>: without it the browser guesses when a server
    # sends no charset, and non-ASCII characters break. The HTML5 parser infers
    # <head>/<body> correctly on its own.
    html = (
        "<!doctype html>\n"
        '<html lang="en">\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '<meta name="color-scheme" content="light dark">\n'
        f"{body}\n"
        "</html>\n"
    )

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")
    print(f"wrote: {out} ({out.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
