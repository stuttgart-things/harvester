# Systemübersicht

Generierte, druckbare Systemübersicht für das stuttgart-things Lab.
Single source of truth ist **`inventory.yaml`** (system, hostname, ip,
description). Daraus werden Diagramm, Tabellen und die IP-Belegung generiert.

Dieses Verzeichnis ist eine **eigenständige MkDocs-Site** mit eigener
`mkdocs.yml` und eigenem `docs/`. Die TechDocs-Konfiguration im Repo-Root
(`mkdocs.yml` + `docs/`, referenziert von `catalog-info.yaml`) bleibt davon
unberührt. Alle Kommandos hier laufen aus `system-inventory/`.

## Nutzung

```bash
cd system-inventory
pip install -r requirements.txt
make d2-install      # einmalig
make serve           # http://127.0.0.1:8000
```

Neuen Host aufnehmen: Block in `inventory.yaml` ergänzen, `make diagram`, fertig.

## Drucken

`mkdocs-print-site-plugin` erzeugt `/print_page/` mit Deckblatt und
Inhaltsverzeichnis. Dort Browser-Druck → „Als PDF sichern".
`docs/stylesheets/print.css` regelt A4-Ränder, wiederholte Tabellenköpfe und
begrenzt das Diagramm auf 22 cm Höhe.

## Prüfungen

`make gen` schlägt fehl (Exit 1) bei doppelten IPs oder Hostnames, ungültigen
IPs, IPs außerhalb der definierten Netze und fehlenden Beschreibungen.
Damit kann die Doku nicht still falsch werden.

## Diagramm

`tools/gen.py` schreibt `docs/topology.d2`, `d2` rendert `docs/topology.svg`.
Labels bewusst als `\n`-Strings statt `|md|`-Blöcke — sonst rendert D2 sie als
`<foreignObject>`, die Shape fällt weg und der Druck bleibt leer.
Gegenprobe: `grep -c foreignObject docs/topology.svg` muss `0` liefern; der
Pages-Workflow prüft das bei jedem Build.

Layout-Engine ist **ELK** (`vars.d2-config.layout-engine` in der generierten
D2-Datei) — der Default `dagre` erzeugt bei Stern-Topologien überkreuzende
Kanten.

Fallback ohne d2-Binary: `python3 tools/gen.py --diagram mermaid`.

## Deployment

`.github/workflows/pages.yml` baut die Site und deployt sie nach GitHub Pages
(nur von `main`). Damit das greift, muss im Repo einmalig
**Settings → Pages → Source: GitHub Actions** gesetzt werden.

## Generierte Dateien

`docs/index.md`, `docs/topology.d2`, `docs/topology.svg` und `site/` sind in
`.gitignore` und werden bei jedem Build neu erzeugt — nicht von Hand editieren.
