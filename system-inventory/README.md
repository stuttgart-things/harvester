# System inventory

Topology diagram and interactive address book for the stuttgart-things lab,
generated from **`inventory.yaml`** (fields: `system`, `hostname`, `ip`,
`description`).

`inventory.yaml` is the only file maintained by hand. `gen.py` turns it into
`topology.d2`, `d2` renders `topology.svg`. Both artifacts are committed so the
diagram shows up directly in GitHub.

![System overview](topology.svg)

There is also an **interactive version on GitHub Pages**: nodes can be dragged
and stay where you drop them, clicking one shows its description, and an
address matrix lays out all 256 addresses of the `/24` — statically assigned,
DHCP pool, free. Diagram and matrix are linked: selecting in one highlights in
the other.

## Adding or changing a host

```bash
cd system-inventory
make d2-install          # once, fetches the d2 binary into ~/.local/bin
make d3-install          # once, fetches vendor/d3.min.js from the npm registry
$EDITOR inventory.yaml
make diagram             # writes topology.d2 + topology.svg
make serve               # builds the D3 page and serves it on :8000
```

Commit `topology.d2` and `topology.svg` along with your change — CI verifies
they match `inventory.yaml`. The HTML page is **not** committed; CI builds it.
It is 95 % embedded d3 bundle, so every inventory change would otherwise be a
300 KB diff.

## Validation

`make gen` (and therefore `make diagram`) exits 1 on:

- duplicate IPs
- duplicate hostnames
- invalid IPs
- IPs outside every network defined under `networks`
- a missing description or hostname

`make check` additionally does what CI does: render, then diff against the
committed artifacts. That way `topology.svg` cannot silently fall behind
`inventory.yaml`.

## Diagram

Two things are deliberate in the generated D2 and worth keeping:

**No `|md|` labels.** D2 renders markdown labels as `<foreignObject>`, which
drops the shape and leaves many PDF/SVG pipelines showing nothing at all.
Labels are plain strings broken with `\n` instead, which yields native
`<text>`/`<tspan>`. `make diagram` aborts if a `<foreignObject>` ends up in the
SVG; the workflow checks the same thing.

**Layout engine ELK**, set through `vars.d2-config.layout-engine` in the
generated D2 file. The default `dagre` produces crossing edges on this star
topology.

Edges run **per system → network** with the host count as the label, not one
edge per host — otherwise the picture becomes unreadable at 20 hosts.

## Interactive page

`build_html.py` combines `inventory.yaml`, `template.html` and
`vendor/d3.min.js` into a single self-contained HTML file. The d3 bundle is
**inlined** — no CDN, no network at runtime, no build step on open. The file
runs over `file://` exactly as it does behind a web server.

Two things only surface when the page is served over HTTP, so they are built in:

- **`<meta charset="utf-8">`.** `template.html` is a fragment; `build_html.py`
  is what turns it into a complete document. Without the declaration the
  browser guesses whenever a server sends no `charset`, and every non-ASCII
  character breaks.
- **No CDN.** `cdn.jsdelivr.net` is blocked on plenty of locked-down networks.
  The bundle is fetched with `npm pack d3@$(D3_VERSION)` into `vendor/`
  (gitignored) and inlined into the page.

Fonts come from Google Fonts; without network the fallback stack takes over.

## Deployment

`.github/workflows/system-inventory.yml` validates the inventory, checks the
committed SVG is current, builds the D3 page and deploys it to GitHub Pages
(from `main` only). This requires **Settings → Pages → Source: GitHub Actions**
to be set once in the repo.

## Optional fields

The network entry understands two optional fields that only the address matrix
reads — `gen.py` ignores them:

```yaml
networks:
  - cidr: 192.168.10.0/24
    gateway: 192.168.10.1
    dhcp_pool: 192.168.10.100-192.168.10.149
```

Without them the matrix only distinguishes assigned from free.

## Generated files

`vendor/` and `site/` are gitignored and rebuilt on every build — do not edit
them by hand. `topology.d2` and `topology.svg` are generated too, but committed
so GitHub can render the diagram.
