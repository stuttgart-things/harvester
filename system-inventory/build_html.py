#!/usr/bin/env python3
"""Baut aus inventory.yaml die interaktive D3-Seite fuer GitHub Pages.

Ergebnis ist eine einzige, eigenstaendige HTML-Datei: das d3-Bundle wird
inline eingebettet, damit die Seite ohne CDN und ohne weiteren Build-Schritt
laeuft - per file:// genauso wie hinter GitHub Pages.

Aufruf: python3 build_html.py [--in inventory.yaml] [--out site/index.html]
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
        print(f"FEHLER: {d3} fehlt - erst 'make d3-install' laufen lassen.", file=sys.stderr)
        return 1

    data = yaml.safe_load(Path(args.src).read_text(encoding="utf-8")) or {}
    data.setdefault("site", {})
    data.setdefault("networks", [])
    data.setdefault("hosts", [])

    body = Path(args.template).read_text(encoding="utf-8")
    # Das Bundle enthaelt kein "</script>", sonst muesste es escaped werden.
    body = body.replace("/*__D3__*/", d3.read_text(encoding="utf-8"))
    body = body.replace("/*__DATA__*/", json.dumps(data, ensure_ascii=False))

    # template.html ist ein Fragment. Fuer die ausgelieferte Seite braucht es ein
    # vollstaendiges Dokument - vor allem <meta charset>: ohne das raet der Browser
    # bei einem Server, der kein charset mitschickt, und die Umlaute kippen.
    # <head>/<body> laesst der HTML5-Parser korrekt selbst entstehen.
    html = (
        "<!doctype html>\n"
        '<html lang="de">\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '<meta name="color-scheme" content="light dark">\n'
        f"{body}\n"
        "</html>\n"
    )

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")
    print(f"geschrieben: {out} ({out.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
