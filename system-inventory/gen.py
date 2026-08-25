#!/usr/bin/env python3
"""Generate the D2 source for the topology diagram from inventory.yaml.

Output:
  topology.d2   - D2 source, rendered to topology.svg by `d2`

Usage: python3 gen.py [--in inventory.yaml] [--out topology.d2] [--strict]
"""

from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from collections import defaultdict
from pathlib import Path

import yaml

# One colour per network - used for edges and the legend.
NET_COLORS = ["#0f766e", "#b45309", "#7c3aed", "#be123c", "#1d4ed8", "#4d7c0f"]


def slug(value: str) -> str:
    """Node ID that D2 accepts."""
    return re.sub(r"[^A-Za-z0-9_]", "_", str(value))


def net_of(ip: str, networks: list[dict]) -> dict | None:
    """Find the network the IP belongs to."""
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
        grouped[h.get("system", "no system")].append(h)
    for entries in grouped.values():
        entries.sort(key=lambda h: str(h.get("hostname", "")))
    return dict(sorted(grouped.items()))


# --------------------------------------------------------------------------
# Validation
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
            problems.append(f"{where}: no hostname set")
        if not h.get("description"):
            problems.append(f"{where}: no description - what is this box for?")

        raw_ip = h.get("ip")
        if not raw_ip:
            problems.append(f"{where}: no IP set")
            continue

        try:
            ipaddress.ip_address(str(raw_ip))
        except ValueError:
            problems.append(f"{where}: '{raw_ip}' is not a valid IP")
            continue

        ip = str(raw_ip)
        if ip in seen_ip:
            problems.append(f"{where}: IP {ip} assigned twice (also {seen_ip[ip]})")
        seen_ip[ip] = where

        host_key = str(name).lower()
        if host_key in seen_host:
            problems.append(
                f"{where}: hostname '{name}' used twice (also {seen_host[host_key]})"
            )
        seen_host[host_key] = where

        if networks and net_of(ip, networks) is None:
            problems.append(f"{where}: IP {ip} is not inside any network defined under 'networks'")

    return problems


# --------------------------------------------------------------------------
# D2
# --------------------------------------------------------------------------
def render_d2(data: dict) -> str:
    """D2 source.

    Labels are deliberately \\n strings, NOT |md| blocks: D2 renders md labels
    as <foreignObject>, which drops the shape and leaves many PDF/SVG
    renderers showing nothing. \\n yields native <text>/<tspan>.
    """
    networks = data.get("networks", []) or []
    hosts = data.get("hosts", []) or []
    grouped = by_system(hosts)

    color = {n["cidr"]: NET_COLORS[i % len(NET_COLORS)] for i, n in enumerate(networks)}

    out = [
        "# generated from inventory.yaml - do not edit by hand",
        "vars: {",
        "  d2-config: {",
        "    layout-engine: elk",
        "  }",
        "}",
        "direction: right",
        "",
    ]

    # Networks as the central nodes
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

    # Systems as containers holding their hosts
    for system, entries in grouped.items():
        sid = slug(system)
        out.append(f'sys_{sid}: "{system}" {{')
        out.append('  style.fill: "#f8fafc"')
        out.append('  style.stroke: "#94a3b8"')
        out.append("  style.font-size: 20")
        for h in entries:
            hid = slug(h.get("hostname", "unknown"))
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

        # One edge per system and network, not per host - otherwise it turns
        # into spaghetti.
        touched: dict[str, int] = defaultdict(int)
        for h in entries:
            n = net_of(str(h.get("ip", "")), networks)
            if n:
                touched[n["cidr"]] += 1
        for cidr, count in touched.items():
            lbl = f"{count} host" if count == 1 else f"{count} hosts"
            out.append(f'sys_{sid} -> net_{slug(cidr)}: "{lbl}" {{')
            out.append("  style: {")
            out.append(f'    stroke: "{color[cidr]}"')
            out.append("    stroke-width: 2")
            out.append("  }")
            out.append("}")
        out.append("")

    # rstrip: the loop appends a blank line after every system block. Without
    # this the file ends on two newlines and end-of-file-fixer complains.
    return "\n".join(out).rstrip("\n") + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", default="inventory.yaml")
    ap.add_argument("--out", dest="out", default="topology.d2")
    ap.add_argument("--strict", action="store_true", help="exit 1 on warnings")
    args = ap.parse_args()

    data = yaml.safe_load(Path(args.src).read_text(encoding="utf-8")) or {}
    problems = validate(data)
    for p in problems:
        print(f"WARN: {p}", file=sys.stderr)

    out = Path(args.out)
    if out.parent != Path(""):
        out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render_d2(data), encoding="utf-8")
    print(f"wrote: {out}")

    return 1 if (problems and args.strict) else 0


if __name__ == "__main__":
    raise SystemExit(main())
