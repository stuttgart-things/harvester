# System inventory

Topology diagram, service catalogue and interactive address book for the
stuttgart-things lab, generated from **`inventory.yaml`**.

`inventory.yaml` is the only file maintained by hand. `gen.py` turns it into
`topology.d2`, `d2` renders `topology.svg`. Both artifacts are committed so the
diagram shows up directly in GitHub.

![System overview](topology.svg)

There is also an **interactive version on GitHub Pages**, split into three
tabs — Topology, Addresses, Services — so nothing has to be scrolled past.
Each tab is deep-linkable (`#services`) and the last one used is remembered
per browser. Nodes can be dragged
and stay where you drop them, clicking one shows its description and the
services it runs, an address matrix lays out all 256 addresses of the `/24`
(statically assigned, DHCP pool, free), and a service index lists everything
running in the lab — grouped by cluster, sortable by any column, filterable by
free text. Diagram and matrix are linked: selecting in one
highlights in the other.

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

## Schema

A host entry is `system`, `hostname`, `ip`, `description`, plus two optional
fields:

```yaml
hosts:
  - system: infra-sthings
    hostname: infra
    ip: 192.168.10.150
    kind: k3s-cluster              # host | k3s-cluster | hypervisor | router
    cluster: infra                 # matches the directory under clusters/
    description: >-
      Single-node k3s cluster `infra.sthings.lab` (Cilium LB VIP).
    services:
      - name: Vault
        fqdn: vault.infra.sthings.lab
        description: PKI for sthings-lab.
      - name: NFS
        port: 2049
        description: Shared storage behind the NFS CSI driver.
```

Both the service index and the host table under **Addresses** are sortable by
any column; the IP column sorts on a zero-padded integer so `.9` lands before
`.110`.

`cluster` names the Kubernetes cluster a host and its services belong to.
Values match the directories under `clusters/`, so the service index can be
read against the GitOps tree. Hosts outside any cluster (router, jump server)
leave it out, and their services sort to the bottom of the index. The service
index is keyed on the cluster rather than the host: for the single-node
clusters the two are the same, so a Host column would only restate the cluster.
The host is named on a row only where it adds something — a cluster served by
more than one host, or a service outside any cluster. Setting
`kind: k3s-cluster` without a `cluster` name is a validation error.

**Services nest under the host that serves them and inherit its IP.** That is
the point of the nesting: Vault and Clusterbook are both published on the same
Cilium LB VIP and told apart by FQDN, not by address — as separate `hosts`
rows they would trip the duplicate-IP check.

Per service, `name` and `description` are required; `fqdn`, `port`, `ip` and
`url` are optional. A service with an `fqdn` is rendered as a link to
`https://<fqdn>`; set `url` when the real entry point differs — a path, a port,
plain http. A service only needs its own `ip` when it gets a separate
load-balancer address — it then joins the duplicate-IP check like a host. A
service with no endpoint at all is fine and lists without a link: Crossplane
and the Clusterbook operator are reached through the Kubernetes API, not over
an ingress.

Chart and app versions are deliberately **not** tracked here. They live in
`clusters/**/*.yaml` and would go stale the moment they were copied.

## Validation

`make gen` (and therefore `make diagram`) exits 1 on:

- duplicate IPs, including a service IP colliding with a host
- duplicate hostnames
- duplicate service FQDNs
- invalid IPs and out-of-range ports
- IPs outside every network defined under `networks`
- a missing description or hostname, or a service without a description
- `kind: k3s-cluster` without a `cluster` name

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

For the same reason a host node shows only its **service count**, never the
services themselves. The topology diagram answers *what is on the network*;
*what runs where* is a different question, and the service index on the HTML
page is where it gets answered.

## Look

The page is **dark by design**, styled to match the Clusterbook app — it is a
console for the same lab, so it wears the same clothes. There is no light
variant on purpose; every colour is painted explicitly so the page never
borrows a host theme it was not built for.

Colours come from `logo.png` (the amber cat, the violet headdress, the
neon-pink script) plus the green/orange status language Clusterbook already
uses. The address-matrix fills are validated as a categorical pair against the
dark surface; the brighter chrome orange sits outside that lightness band and
is used only for text, where contrast is what matters. Violet carries the
chrome and "statically assigned", amber the DHCP pool, pink the selection
state — so no two of them ever mean the same thing on one screen.

The logo sits straight on the background rather than on a plaque: its letters
are white and the cat is amber, both of which read on the dark, and a soft
violet glow ties it in. It is inlined as a data URI like the d3 bundle.

The colophon carries the source file, the commit the page was built from and
a UTC build timestamp — the page is generated, so "how fresh is this" is a
fair question to answer on it.

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

## PDF

CI renders `site/inventory.pdf` with headless Chrome and uploads it as a build
artifact on every run. Because it is written into `site/`, Pages serves it
alongside the page — the colophon links to it as **download PDF**.

Building it in CI rather than leaving it to the browser print dialog is the
point: no page chrome, fixed margins, no scaling surprises, and the same
output every time. Locally:

```bash
make pdf                       # uses `google-chrome` by default
CHROME=chromium make pdf       # or point it at whatever you have
```

## Printing from the browser

The page also prints straight from the browser, in colour, without anyone
having to tick "Background graphics" in the print dialog. Browsers drop backgrounds by default, which would print
the address matrix blank; `print-color-adjust: exact` on the elements whose
fill carries meaning forces them through.

The print stylesheet flips the surfaces to white and the ink to black — a dark
UI on paper wastes toner and reads badly — while keeping the colours that mean
something: violet for assigned, amber for the pool, the cluster tags. The
wordmark keeps a dark ground of its own, since it is white with a black
outline and would otherwise vanish into the page.

All three tabs print, one per page, and the host table under Addresses is
forced open: on paper there is nothing to click, so hiding two thirds of the
inventory behind tabs makes no sense. Tabs, the filter box, the reset button
and the detail panel are left out entirely — the last of those would otherwise
print an instruction ("select a host…") that cannot be followed on paper.

The diagram is not re-laid-out for print. `beforeprint` fires before the print
styles apply, so it would still measure the on-screen box; the print height is
sized to the viewBox aspect instead, which is deterministic.

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
