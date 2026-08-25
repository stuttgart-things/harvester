#!/usr/bin/env python3
"""Erzeugt aus inventory.yaml die MkDocs-Seite inkl. D2-Diagramm.

Ausgabe:
  docs/index.md      - Doku (Tabellen je System + IP-Index)
  docs/topology.d2   - D2-Quelle, wird per `d2` zu docs/topology.svg gerendert

Aufruf: python3 tools/gen.py [--in inventory.yaml] [--out docs] [--strict]
"""

from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from collections import defaultdict
from pathlib import Path

import yaml

# Farben je Netz - werden fuer Kanten und Legende verwendet.
NET_COLORS = ["#0f766e", "#b45309", "#7c3aed", "#be123c", "#1d4ed8", "#4d7c0f"]


def slug(value: str) -> str:
    """D2-taugliche Node-ID."""
    return re.sub(r"[^A-Za-z0-9_]", "_", str(value))


def net_of(ip: str, networks: list[dict]) -> dict | None:
    """Findet das Netz, in dem die IP liegt."""
    try:
        addr = ipaddress.ip_address(str(ip))
    except ValueError:
        return None
    for n in networks:
        try:
            if addr in ipaddress.ip_network(n["cidr"]):
                return n
        except ValueError:
            continue
    return None


def by_system(hosts: list[dict]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = defaultdict(list)
    for h in hosts:
        grouped[h.get("system", "ohne System")].append(h)
    for entries in grouped.values():
        entries.sort(key=lambda h: str(h.get("hostname", "")))
    return dict(sorted(grouped.items()))


# --------------------------------------------------------------------------
# Validierung
# --------------------------------------------------------------------------
def validate(data: dict) -> list[str]:
    problems: list[str] = []
    networks = data.get("networks", []) or []
    seen_ip: dict[str, str] = {}
    seen_host: dict[str, str] = {}

    for h in data.get("hosts", []) or []:
        name = h.get("hostname", "<ohne hostname>")
        where = f"{h.get('system', '?')}/{name}"

        if not h.get("hostname"):
            problems.append(f"{where}: kein hostname gesetzt")
        if not h.get("description"):
            problems.append(f"{where}: keine Beschreibung - wofuer ist die Kiste da?")

        raw_ip = h.get("ip")
        if not raw_ip:
            problems.append(f"{where}: keine IP gesetzt")
            continue

        try:
            ipaddress.ip_address(str(raw_ip))
        except ValueError:
            problems.append(f"{where}: '{raw_ip}' ist keine gueltige IP")
            continue

        ip = str(raw_ip)
        if ip in seen_ip:
            problems.append(f"{where}: IP {ip} doppelt vergeben (auch {seen_ip[ip]})")
        seen_ip[ip] = where

        host_key = str(name).lower()
        if host_key in seen_host:
            problems.append(
                f"{where}: Hostname '{name}' doppelt vergeben (auch {seen_host[host_key]})"
            )
        seen_host[host_key] = where

        if networks and net_of(ip, networks) is None:
            problems.append(f"{where}: IP {ip} liegt in keinem unter 'networks' definierten Netz")

    return problems


# --------------------------------------------------------------------------
# D2
# --------------------------------------------------------------------------
def render_d2(data: dict) -> str:
    """D2-Quelle.

    Labels bewusst als \\n-Strings, NICHT als |md|-Bloecke: D2 rendert
    md-Labels als <foreignObject>, dabei faellt die Shape weg und viele
    PDF-/SVG-Renderer zeigen nichts an. \\n ergibt natives <text>/<tspan>.
    """
    networks = data.get("networks", []) or []
    hosts = data.get("hosts", []) or []
    grouped = by_system(hosts)

    color = {n["cidr"]: NET_COLORS[i % len(NET_COLORS)] for i, n in enumerate(networks)}

    out = [
        "# generiert aus inventory.yaml - nicht von Hand editieren",
        "vars: {",
        "  d2-config: {",
        "    layout-engine: elk",
        "  }",
        "}",
        "direction: right",
        "",
    ]

    # Netze als zentrale Knoten
    for n in networks:
        nid = slug(n["cidr"])
        label = "\\n".join(x for x in [n.get("name", ""), n["cidr"]] if x)
        out.append(f'net_{nid}: "{label}" {{')
        out.append("  shape: cloud")
        out.append("  style: {")
        out.append(f'    fill: "{color[n["cidr"]]}"')
        out.append('    font-color: "#ffffff"')
        out.append("    bold: true")
        out.append("  }")
        out.append("}")
    out.append("")

    # Systeme als Container mit ihren Hosts
    for system, entries in grouped.items():
        sid = slug(system)
        out.append(f'sys_{sid}: "{system}" {{')
        out.append('  style.fill: "#f8fafc"')
        out.append('  style.stroke: "#94a3b8"')
        out.append("  style.font-size: 20")
        for h in entries:
            hid = slug(h.get("hostname", "unbekannt"))
            label = "\\n".join(
                x for x in [str(h.get("hostname", "")), str(h.get("ip", ""))] if x
            )
            out.append(f'  {hid}: "{label}" {{')
            out.append("    shape: rectangle")
            out.append("    style: {")
            out.append('      fill: "#ffffff"')
            out.append('      stroke: "#475569"')
            out.append("    }")
            out.append("  }")
        out.append("}")

        # Eine Kante je System und Netz, nicht je Host - sonst wird es Spaghetti.
        touched: dict[str, int] = defaultdict(int)
        for h in entries:
            n = net_of(str(h.get("ip", "")), networks)
            if n:
                touched[n["cidr"]] += 1
        for cidr, count in touched.items():
            lbl = f"{count} Host" if count == 1 else f"{count} Hosts"
            out.append(f'sys_{sid} -> net_{slug(cidr)}: "{lbl}" {{')
            out.append("  style: {")
            out.append(f'    stroke: "{color[cidr]}"')
            out.append("    stroke-width: 2")
            out.append("  }")
            out.append("}")
        out.append("")

    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# Markdown
# --------------------------------------------------------------------------
def render_markdown(data: dict, problems: list[str], diagram: str = "d2") -> str:
    site = data.get("site", {}) or {}
    networks = data.get("networks", []) or []
    hosts = data.get("hosts", []) or []
    grouped = by_system(hosts)
    md: list[str] = []

    md.append(f"# {site.get('name', 'Systemuebersicht')}")
    if site.get("subtitle"):
        md.append(f"*{site['subtitle']}*")
    md.append("")
    md.append(
        '!!! info "Generiert"\n'
        "    Diese Seite entsteht aus `inventory.yaml`. "
        "Änderungen bitte **nur dort** vornehmen."
    )
    md.append("")

    md.append("## Überblick")
    md.append("")
    if diagram == "d2":
        md.append("![Systemübersicht](topology.svg){ .topology }")
    else:
        md.append("``` mermaid")
        md.append(render_mermaid(data))
        md.append("```")
    md.append("")

    if networks:
        md.append("## Netze")
        md.append("")
        md.append("| Netz | CIDR | Hosts | Beschreibung |")
        md.append("| --- | --- | ---: | --- |")
        for n in networks:
            count = sum(
                1 for h in hosts if net_of(str(h.get("ip", "")), [n]) is not None
            )
            md.append(
                f"| `{n.get('name', '')}` | `{n['cidr']}` | {count} | "
                f"{n.get('description', '')} |"
            )
        md.append("")

    md.append("## Systeme")
    md.append("")
    for system, entries in grouped.items():
        md.append(f"### {system}")
        md.append("")
        md.append("| Hostname | IP | Beschreibung |")
        md.append("| --- | --- | --- |")
        for h in entries:
            md.append(
                f"| `{h.get('hostname', '')}` | `{h.get('ip', '')}` | "
                f"{h.get('description', '')} |"
            )
        md.append("")

    md.append("## IP-Belegung")
    md.append("")
    md.append("| IP | Hostname | System | Beschreibung |")
    md.append("| --- | --- | --- | --- |")

    def sort_key(h: dict):
        try:
            return (0, int(ipaddress.ip_address(str(h.get("ip", "")))))
        except ValueError:
            return (1, 0)

    for h in sorted(hosts, key=sort_key):
        md.append(
            f"| `{h.get('ip', '')}` | `{h.get('hostname', '')}` | "
            f"{h.get('system', '')} | {h.get('description', '')} |"
        )
    md.append("")

    if problems:
        md.append("## Konsistenz-Warnungen")
        md.append("")
        for p in problems:
            md.append(f"- :warning: {p}")
        md.append("")

    return "\n".join(md) + "\n"


# --------------------------------------------------------------------------
# Mermaid (Fallback ohne d2-Binary)
# --------------------------------------------------------------------------
def render_mermaid(data: dict) -> str:
    networks = data.get("networks", []) or []
    grouped = by_system(data.get("hosts", []) or [])
    lines = ["flowchart LR"]
    for n in networks:
        lines.append(f'  net_{slug(n["cidr"])}(("{n.get("name", "")}<br/>{n["cidr"]}"))')
    for system, entries in grouped.items():
        sid = slug(system)
        lines.append(f'  subgraph sys_{sid}["{system}"]')
        for h in entries:
            lines.append(
                f'    {slug(h.get("hostname", ""))}["{h.get("hostname", "")}'
                f'<br/>{h.get("ip", "")}"]'
            )
        lines.append("  end")
        touched = {
            n["cidr"]
            for h in entries
            if (n := net_of(str(h.get("ip", "")), networks)) is not None
        }
        for cidr in touched:
            lines.append(f"  sys_{sid} --> net_{slug(cidr)}")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", default="inventory.yaml")
    ap.add_argument("--out", dest="out", default="docs")
    ap.add_argument("--strict", action="store_true", help="Exit 1 bei Warnungen")
    ap.add_argument("--diagram", choices=["d2", "mermaid"], default="d2")
    args = ap.parse_args()

    data = yaml.safe_load(Path(args.src).read_text(encoding="utf-8")) or {}
    problems = validate(data)
    for p in problems:
        print(f"WARN: {p}", file=sys.stderr)

    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "index.md").write_text(
        render_markdown(data, problems, args.diagram), encoding="utf-8"
    )
    (outdir / "topology.d2").write_text(render_d2(data), encoding="utf-8")
    print(f"geschrieben: {outdir/'index.md'}, {outdir/'topology.d2'}")

    return 1 if (problems and args.strict) else 0


if __name__ == "__main__":
    raise SystemExit(main())
