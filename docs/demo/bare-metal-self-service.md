# Live-Demo: Self-Service auf Bare Metal

**Dauer:** 30 Minuten · **Bühne:** `sthings.lab` · **Story:** Von einem physischen
Node zu einer entwickler-bestellten VM — ohne dass ein Entwickler jemals
Harvester zu Gesicht bekommt.

---

## Vorbemerkung zum Titel

Der Titel „Bare-Metal-Provisionierung" kann zwei Dinge meinen. Was dieses Lab
zeigt, ist die **zweite** Lesart:

| Lesart | Im Lab vorhanden? |
|---|---|
| Physische Server per PXE/Redfish/Metal3 ausrollen (Layer 0) | **Nur als Runbook** — `docs/install.md` beschreibt Node, Netz, Disks und die äquivalente automatische `config.yaml` (PXE-tauglich). Kein Metal3/Tinkerbell, keine Live-Neuinstallation in 30 Minuten. |
| Self-Service auf einer Bare-Metal-Plattform (Layer 1–2) | **Vollständig live** — Harvester/SUSE Virtualization auf dem Blech, darüber Backstage → Git → Flux → Crossplane. |

Empfehlung: Layer 0 in 3–4 Minuten als **reproduzierbares Artefakt** zeigen
(Runbook + `config.yaml`), nicht live installieren. Der Rest der Zeit gehört dem
Self-Service-Pfad. Wenn das Publikum echtes PXE-Provisioning physischer Server
erwartet, den Titel vorher auf „Self-Service **auf** Bare Metal" schärfen — sonst
entsteht eine Erwartungslücke, die die Demo nicht schließen kann.

---

## Die Bühne (was tatsächlich läuft)

Eine physische Maschine, alles andere sind VMs darauf — das ist die Pointe der
Demo und sollte am Anfang explizit gesagt werden.

| Ebene | System | Adresse | Rolle |
|---|---|---|---|
| Blech | `harvester` | `192.168.10.110`, VIP `.139` | Harvester v1.8.0 (SUSE Virtualization), Single Node, SL Micro 6.2 |
| VM | `infra` | `192.168.10.150` | k3s: Vault (PKI), Clusterbook (IP/DNS), NFS |
| VM | `xplane` | `192.168.10.155` | k3s: **Crossplane**, claim-machinery-api, Komoplane |
| VM | `platform` | `192.168.10.160` | k3s: **Backstage**, Harbor, MinIO (Golden Images), Rancher, ArgoCD |
| Netz | `ddwrt` | `192.168.10.1` | Gateway, DNS `*.sthings.lab`, DHCP `.100–.149` |

Quelle: `system-inventory/inventory.yaml` → `topology.svg` + die interaktive
GitHub-Pages-Seite. **Das ist der beste Einstiegs-Slide der ganzen Demo**, weil
er aus dem Repo generiert wird und nicht aus Visio.

---

## Ablauf

### 0 · Architektur-Frame (3 min)

Interaktive Inventory-Seite öffnen (Tab *Topology*), auf `harvester` klicken.

> „Das hier ist ein Rechner. Alles andere in diesem Bild ist eine VM darauf.
> Und dieses Bild ist kein Diagramm, das jemand gemalt hat — es fällt aus
> `inventory.yaml` heraus, CI bricht, wenn es veraltet."

Dann der Zielsatz für die nächsten 25 Minuten:

> „Ein Entwickler will eine VM. Er bekommt sie über einen Pull Request. Er hat
> keinen Zugang zu Harvester, keinen Zugang zum Cluster, kein Ticket geschrieben."

**Sichtbar machen:** `make check` in `system-inventory/` bricht bei doppelten
IPs — die Adressvergabe ist ein CI-Gate, kein Excel-Sheet.

---

### 1 · Layer 0 — das Blech (4 min)

Harvester-UI (`harvester.sthings.lab`) → Hosts, Disks, VM-Networks. Ein Node,
drei laufende VMs.

Dann `docs/install.md` daneben: dieselben Werte als Runbook — Bond `enp5s0`,
MAC, VIP `.139`, CIDRs, Disk-Layout, DD-WRT-Reservierung. Und der Abschnitt
**„Equivalent automated `config.yaml`"**: derselbe Node, unbeaufsichtigt per
PXE/Autoinstall.

> „Der Hypervisor ist hier ein Artefakt, kein Klick-Protokoll. Wenn das Blech
> morgen abraucht, ist es eine Datei, kein Gedächtnisprotokoll."

Ehrlich bleiben: der Node wurde per TUI-Wizard installiert, die `config.yaml`
ist die dokumentierte äquivalente Automatisierung. Genau diese Ehrlichkeit ist
später ein Lessons-Learned-Punkt.

---

### 2 · Layer 1 — Golden Images als Self-Service mit zwei Geschwindigkeiten (5 min)

`packer/` zeigen — die Governance steckt im Ordner-Layout:

```
packer/_build/          gemeinsame Build-Logik, EINE Kopie
packer/golden/          kuratierte Basis  → Review-gated, kein Auto-Merge
packer/dev/             Spielwiese        → baut, lädt hoch, auto-merged
```

`packer/dev/u26-dev/users.yaml` öffnen: ein Entwickler hängt seinen SSH-Key an,
`packages.yaml`: seine Pakete. `packer-pr-build.yml` erkennt den geänderten
Ordner, baut **nur das Delta** auf dem publizierten Golden-Artefakt aus MinIO,
lädt es als `VirtualMachineImage` nach Harvester und merged bei grün.
Berührt derselbe PR ein `golden/`-Verzeichnis, erzwingt CI die Review.

**Live-Empfehlung:** einen bereits gemergten Dev-Image-PR aufrufen und den grünen
Run zeigen, dazu das fertige Image in der Harvester-UI. Ein Packer-Build live
laufen zu lassen kostet die halbe Demo.

> „Zwei Tiers, ein Mechanismus. Der Unterschied ist nicht das Tool, sondern
> welcher Ordner angefasst wird."

---

### 3 · Layer 2 — Der Hauptakt: VM per Pull Request (12 min)

Der durchgehende Pfad. Vier Fenster vorbereiten: **Backstage**, **GitHub**,
**Terminal (kubectl/flux gegen `xplane`)**, **Harvester-UI**.

**3.1 Bestellung (2 min)** — Backstage (`backstage.platform.sthings.lab`),
Template *Crossplane Claim*, Template-Auswahl `virtualmachine-harvester`,
Parameter ausfüllen: Name, CPU, RAM, Disk, Image, Netz. Absenden.

Was dahinter passiert, dabei sagen: Backstage ruft die **claim-machinery-api**
(`claims.platform.sthings.lab`), die rendert das **KCL**-Template aus
`stuttgart-things/kcl` — die Katalog-URLs stehen in `api-templates-profiles.yaml`.

**3.2 Der PR (3 min)** — GitHub, der frisch geöffnete PR gegen dieses Repo:

```
claims/apps/<name>/<template>.yaml     # der Crossplane-Claim
claims/apps/<name>/kustomization.yaml  # Flux-Einstieg
claims/apps/<name>/catalog-info.yaml   # Backstage-Katalogeintrag
claims/apps/kustomization.yaml         # Parent, um den Eintrag ergänzt
claims/registry.yaml                   # Inventar-Eintrag
```

Das ist der Punkt, an dem die Demo entweder zündet oder nicht — **den Diff
wirklich zeigen**. Vier Dinge daran benennen:

1. Der Claim ist deklarativ und lesbar (`claims/apps/dev-vm/harvestervm-developer.yaml`
   als Referenz danebenlegen: PVC, cloud-init, CPU/RAM, Netz).
2. Der **Katalogeintrag entsteht mit der Ressource**, nicht später von Hand.
3. `registry.yaml` ist das Inventar — Git ist die Datenbank, es gibt keine zweite.
4. CI läuft: *Lint Claims*, *PR Lint*, *Catalog Index*.

Merge.

**3.3 Reconcile (4 min)** — Terminal gegen `xplane`:

```bash
flux reconcile source git harvester            # statt 1 min Poll-Intervall zu warten
flux reconcile kustomization harvester-claims-apps
kubectl get harvestervm,pvc -A -w
```

Parallel **Komoplane** (`komoplane.xplane.sthings.lab`): der Composition-Baum —
Claim → XR → Managed Resources. Hier wird sichtbar, dass Crossplane über
`ProviderConfig harvester` in den *anderen* Cluster schreibt.

**3.4 Die VM (3 min)** — Harvester-UI: PVC wird angelegt, VM bootet,
Guest-Agent meldet die IP. Dann aus dem Terminal per SSH rein.

> „Von *Formular abgeschickt* bis *SSH* — und der einzige menschliche Eingriff
> dazwischen war ein Merge-Klick."

**3.5 Rückweg in den Katalog (kurz)** — Backstage-Katalog neu laden: die neue
Komponente ist da, weil `catalog-info.yaml` im selben PR lag und
`.backstage/catalog-index.sh` (Catalog-Index-Bot) sie in
`catalog-locations.yaml` aufgenommen hat.

> **Deadtime-Trick:** Während die VM bootet, den zweiten, vorbereiteten PR
> mergen (siehe *Plan B*) oder Abschnitt 4 vorziehen. Nie schweigend auf einen
> Boot warten.

---

### 4 · Day 2 — Löschen ist der ehrlichere Teil (3 min)

```bash
claims delete --repo stuttgart-things/harvester \
  --resource-name <name> --category apps --git-push --create-pr
```

PR zeigen: Verzeichnis weg, Parent-Kustomization bereinigt, Registry-Eintrag
weg. Mergen → Flux `prune: true` → die VM verschwindet aus Harvester, die
Komponente aus dem Backstage-Katalog.

> „Es gibt keinen zweiten Weg. Wer die VM in der Harvester-UI löscht, bekommt
> sie von Flux zurück."

Das ist der Abschnitt, den die meisten Self-Service-Demos weglassen — und
genau der, nach dem im Betrieb gefragt wird.

---

### 5 · Der Closer, falls Zeit bleibt (2 min, optional)

Derselbe Mechanismus, größeres Objekt: `ranchercluster-harvester-bootstrap` aus
`api-templates-profiles.yaml`. Ein Claim, ein PR — und es entsteht kein
einzelner Node, sondern ein ganzer Kubernetes-Cluster auf demselben Blech.
Dazu `ansiblerun-baseos` für die Konfiguration nach dem Boot.

> „Die Größe des Objekts ändert am Weg nichts. Das ist der eigentliche Gewinn."

---

## Zeitplan

| Min | Abschnitt | Fenster |
|---|---|---|
| 0–3 | Architektur / Inventory | Browser: Inventory-Seite |
| 3–7 | Layer 0: Blech + Runbook | Harvester-UI, `docs/install.md` |
| 7–12 | Layer 1: Golden/Dev Images | GitHub PR, Harvester Images |
| 12–24 | **Layer 2: VM per PR** | Backstage → GitHub → Terminal → Harvester |
| 24–27 | Delete / Day 2 | Terminal, GitHub |
| 27–30 | Lessons Learned | Slide |

Puffer ist knapp. Bei Zeitdruck fällt **zuerst Abschnitt 5**, dann Abschnitt 1
auf zwei Minuten zusammen. Abschnitt 3 und 4 sind unantastbar.

---

## Plan B (vorher aufsetzen, nicht improvisieren)

| Risiko | Vorbereitung |
|---|---|
| Flux-Intervall (1 min Source, 5 min Kustomization) | `flux reconcile` im Terminal-History; nie auf den Poll warten |
| VM-Boot dauert | Zweiter, identischer PR bereits gemergt und die VM **läuft** — als Schnitt „hier eine, die ich vorbereitet habe" |
| claim-machinery-api / Backstage nicht erreichbar | Denselben Claim per `claims render --git-push --create-pr` aus dem Terminal — das ist ohnehin die Kernaussage „Backstage ist UI, keine Voraussetzung" |
| Image fehlt in Harvester | `harvester-images/import-golden.sh` vorher gelaufen; **Achtung private CA**, ohne `additional-ca` schlägt der Download an TLS fehl |
| Packer-Build zu langsam | Nur gemergten PR + fertiges `VirtualMachineImage` zeigen |
| Live-Netz/DNS wackelt | Screenshots von PR-Diff, Komoplane-Baum und laufender VM in der Hinterhand |

**Vor der Demo abhaken:** Golden-Images in Harvester importiert · `additional-ca`
gesetzt · Backstage-Katalog frisch reindiziert · alter Demo-Claim aufgeräumt
(Name ist sonst belegt) · Terminal-History vorbereitet · Schriftgrößen.

---

## Lessons Learned — Vorschlag

Der bestehende Slide hat drei Bullets im Ton „Erkenntnis, nicht Feature". In
demselben Ton, passend zu **dieser** Demo. Drei bis vier auswählen — mehr
trägt der Slide nicht.

**Empfohlene Auswahl (die stärksten vier):**

- **Git ist das Interface, der Pull Request ist das Ticket.**
  Self-Service heißt nicht, Entwicklern Zugang zur Virtualisierung zu geben —
  sondern ihnen den Zugang zu ersparen.

- **Die Governance steckt im Repo-Layout, nicht im Prozessdokument.**
  `golden/` ist review-pflichtig, `dev/` merged automatisch. Derselbe
  Mechanismus, unterschiedliche Geschwindigkeit — durchgesetzt von CI,
  nicht von Disziplin.

- **Der Katalog muss aus derselben Quelle fallen wie die Ressource.**
  `catalog-info.yaml` entsteht im selben PR wie der Claim. Ein Portal, das
  nachgepflegt werden muss, ist nach zwei Wochen eine Lügenmaschine.

- **Löschen ist der schwierigere Teil.**
  Ohne `prune` und ohne Registry bleibt das Blech voll. Erst wenn der Rückweg
  automatisiert ist, ist es eine Plattform und kein Bestellformular.

**Weitere, falls ein Bullet ausgetauscht werden soll:**

- **Bare Metal bleibt — es hört nur auf, Handarbeit zu sein.**
  Der Hypervisor-Node ist ein reproduzierbares Artefakt (`config.yaml`, PXE),
  kein Gedächtnisprotokoll.

- **Backstage darf keine Voraussetzung sein.**
  Alles, was das Portal kann, kann auch die CLI. Sonst ist das schönste
  Entwicklerportal der teuerste Single Point of Failure im Rechenzentrum.

- **Ein Renderer, viele Objekte.**
  VM, Namespace, Volume, Ansible-Run, ganzer Cluster — derselbe Weg. Der Wert
  liegt im Pfad, nicht in der Anzahl der Templates.

- **Die Wahrheit über das Lab gehört ins Repo.**
  IP-Vergabe und Topologie sind generiert und CI-geprüft. Ein Diagramm, das
  jemand malt, ist beim nächsten Deployment falsch.

### Anschluss an den bestehenden Slide

Die drei vorhandenen Bullets (gemeinsame Plattform/API · Virtualisierung bleibt,
das Betriebsmodell ändert sich · KubeVirt bringt VMs ins Kubernetes-Modell)
sind die **Was-ändert-sich**-Ebene. Die Bullets oben sind die
**Wie-betreibt-man-das**-Ebene. Wenn beide Slides nebeneinanderstehen sollen:
den bestehenden als „Lessons learned — Technologie", diesen als
„Lessons learned — Betrieb" führen.
