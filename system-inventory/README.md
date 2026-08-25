# Systemübersicht

Topologie-Diagramm des stuttgart-things Labs, generiert aus **`inventory.yaml`**
(Felder: `system`, `hostname`, `ip`, `description`).

`inventory.yaml` ist die einzige Datei, die von Hand gepflegt wird. `gen.py`
erzeugt daraus `topology.d2`, `d2` rendert `topology.svg`. Beide Artefakte sind
eingecheckt, damit das Diagramm direkt in GitHub sichtbar ist.

![Systemübersicht](topology.svg)

## Host aufnehmen oder ändern

```bash
cd system-inventory
make d2-install          # einmalig, holt das d2-Binary nach ~/.local/bin
$EDITOR inventory.yaml
make diagram             # schreibt topology.d2 + topology.svg
```

Beide generierten Dateien mit committen — CI prüft, dass sie zu
`inventory.yaml` passen.

## Prüfungen

`make gen` (und damit `make diagram`) schlägt mit Exit 1 fehl bei:

- doppelten IPs
- doppelten Hostnames
- ungültigen IPs
- IPs außerhalb aller unter `networks` definierten Netze
- fehlender Beschreibung oder fehlendem Hostname

`make check` macht zusätzlich das, was CI macht: rendern und gegen die
eingecheckten Artefakte diffen. Damit kann `topology.svg` nicht stillschweigend
hinter `inventory.yaml` zurückfallen.

## Zwei Fallstricke im Generator

**Keine `|md|`-Labels.** D2 rendert Markdown-Labels als `<foreignObject>` —
dabei fällt die Shape weg und viele PDF-/SVG-Pipelines zeigen gar nichts an.
Labels sind deshalb normale Strings mit `\n`, was natives `<text>`/`<tspan>`
ergibt. `make diagram` bricht ab, falls doch ein `<foreignObject>` im SVG landet.

**Layout-Engine ELK**, gesetzt über `vars.d2-config.layout-engine` in der
generierten D2-Datei. Der Default `dagre` erzeugt bei dieser Stern-Topologie
überkreuzende Kanten.

Kanten laufen bewusst **je System → Netz** mit der Host-Anzahl als Label, nicht
eine Kante pro Host — sonst wird das Bild bei 20 Hosts unlesbar.
