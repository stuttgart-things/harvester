# clusters/edge

A single-node **k3s** cluster for the edge box, a LattePanda Mu (Intel N100,
8GB LPDDR5, 64GB eMMC). It runs only occasionally, and when it runs it has to
manage with **only that one node**: no OpenBao, no NFS, no lab DNS, no S3, no
Rancher. It is tested on a lab VM first (`edge-tt-test1`, LabDA), then built
on the hardware.

The chain: VM + base OS (Backstage request) → k3s + Cilium ([`k3s/`](./k3s/))
→ Flux Operator → the infra bundle
→ homerun2 → tabletennis. Everything Flux reconciles comes from **one OCI
artifact** of `stuttgart-things/flux` ([`sources.yaml`](./sources.yaml)),
not from Git.

> **Status: in progress.** Test VM with base OS, k3s + Cilium done
> ([`k3s/`](./k3s/)); LB address and DNS reserved. Flux bootstrap is next.

| | |
|---|---|
| Cluster | `edge` |
| Test node | `edge-tt-test1` / 10.100.136.89 (LabDA vSphere, 8 vCPU / 15Gi / 128Gi) |
| Target | LattePanda Mu: N100 / 8GB / 64GB eMMC |
| LB address | `10.100.136.223` (LabDA Clusterbook, `edge-tt-test1`), the Cilium VIP of the Gateway |
| Domain | `edge-tt-test1.4sthings.tiab.ssc.sva.de` (Clusterbook DNS wildcard) for the lab test; changes on the hardware |
| Kubernetes | k3s `v1.35.9+k3s1` on sqlite/kine, Cilium 1.20.2 (cilium-cli 0.20.1, Gateway API v1.6.1), no kube-proxy, no flannel, no traefik, no servicelb |
| Storage | k3s `local-path` (the default class). Nothing here is meant to survive the box. |
| Certificates | cert-manager, self-signed root → `cluster-ca` → `*.<INFRA_DOMAIN>` |
| Secrets | SOPS only: [`apps/edge-secrets-subst.enc.yaml`](./apps/edge-secrets-subst.enc.yaml), decrypted by Flux |
| GitOps | Flux Operator, syncing `clusters/edge`; content from `oci://ghcr.io/stuttgart-things/flux/repo` |

```bash
export KUBECONFIG=~/.kube/edge-tt-test1
export SOPS_AGE_KEY=...          # the repo's age key
export GITHUB_USER=... GITHUB_TOKEN=... AGE_PUB=...
```

---

## Layout

```
clusters/edge/
├── kustomization.yaml   flux-system applies only: config, secrets, sources, infra.yaml, apps.yaml
├── config.yaml  secrets.yaml        FluxInstance + git/sops secrets (committed by the bootstrap)
├── sources.yaml         OCIRepository flux-repo -> ghcr.io/stuttgart-things/flux/repo
├── infra.yaml           Kustomization edge-infra -> ./infra   (wait: true)
├── apps.yaml            Kustomization edge-apps  -> ./apps    (dependsOn edge-infra)
├── infra/               infra-platform.yaml: the flux infra bundle
├── apps/                homerun2, tabletennis, edge-secrets-subst (SOPS),
│   └── homerun2-notify/   the notification-catcher ConfigMap (own Kustomization)
└── k3s/                 Ansible for k3s + Cilium -- never read by Flux (.sourceignore)
```

Two layers, so the apps start only once the whole infra bundle is Ready, and
can be stopped or removed without touching it (`flux suspend ks edge-apps`).

## What runs here, and what deliberately does not

| Layer | Selected | Left out, and why |
|---|---|---|
| Ansible | `sthings.baseos.setup`, `sthings.rke.k3s_cluster` | the `k3s` play (ingress-nginx + a cert-manager that wants `root-ca`); `k3s_arm` (installs no Cilium, so the node would have no CNI) |
| infra bundle | `cilium-lb`, `cilium-gateway`, `cert-manager-install`, `cert-manager-selfsigned`, `cnpg-operator`, `reloader` | vault issuer, ESO, sops-git, nfs-csi, coredns-lab-zone, velero, trust-manager, openebs, headlamp, flux-web. Each is explained in `infra/infra-platform.yaml` |
| homerun2 | `profiles/sops` + `sops-routes`, as on homerun2-dev | `redis-lb` (nothing off the node reads Redis); the Teams webhook (notification-catcher stays in dry run) |
| tabletennis | `profiles/sops` + `zaehlwerk-panel-homerun2` | DB backup (no S3); scoreboard + handover (would need the self-signed CA in zaehlwerk's trust) |

## 1. Address and name

**Lab VM:** the test node sits in LabDA, so the Gateway VIP comes from that
network. Reserved on 2026-10-03:

```bash
curl -s -X POST http://clusterbook.sthings-infra.4sthings.tiab.ssc.sva.de/api/v1/networks/10.100.136/reserve \
  -H 'Content-Type: application/json' \
  -d '{"cluster":"edge-tt-test1","status":"ASSIGNED","create_dns":true,"ip":"223"}'
# {"cluster":"edge-tt-test1","digit":"223","dns":"ok","ip":"10.100.136.223",...,"status":"ASSIGNED:DNS"}
dig +short schmetterpause.edge-tt-test1.4sthings.tiab.ssc.sva.de   # 10.100.136.223
```

The address is in `CILIUM_LB_IP_START`/`STOP`, and the domain in
`INFRA_DOMAIN` (infra/infra-platform.yaml) and `DOMAIN` (apps/homerun2.yaml,
apps/tabletennis.yaml).

**Edge box:** there is no Clusterbook and no lab router. Pick a free address
in the edge network for the VIP and change the same two values. See
[DNS on the edge](#dns-on-the-edge).

## 2. The node: VM + base OS

The lab test node is `edge-tt-test1` (LabDA vSphere, Ubuntu 26.04). It was
requested through the Backstage `request-vm` template
(stuttgart-things#3415). The Dapr worker on `cicd-machinery-test5` ran
`create-terraform-vm`, whose build PR (#3418) did Terraform and
`sthings.baseos.setup`. Nothing in this repo builds the VM.

## 3. k3s + Cilium

Ansible, not Flux: [`k3s/`](./k3s/) holds the inventory, the vars and
the runbook (CLI first, then Dagger). Flux never reads that folder
([`.sourceignore`](./.sourceignore)).

## 4. The flux artifact

[`sources.yaml`](./sources.yaml) reads
`oci://ghcr.io/stuttgart-things/flux/repo:v1.111.0`. The flux Release
workflow pushes that artifact on every release, starting with v1.111.0
([flux#621](https://github.com/stuttgart-things/flux/issues/621),
[#622](https://github.com/stuttgart-things/flux/pull/622)). It is public, so
there is nothing to push by hand and no pull secret is needed. To move forward,
bump the tag.

Checked on 2026-10-03: `flux pull artifact` of v1.111.0 contains every path
this cluster renders, and an anonymous manifest fetch returns 200.

**Why the whole repo:** the infra bundle's children use paths from the repo
root (`./infra/cert-manager/...`, and `./apps/cnpg-operator` from an infra
component). The per-component artifacts `flux/infra/<name>` do not contain
them. The bundle's children also hard-code `sourceRef.kind: GitRepository`.
`infra/infra-platform.yaml` patches that to `OCIRepository`; flux#621 proposes a
`FLUX_SOURCE_KIND` so the patch can go.

Rendered locally at v1.110.3 (identical for these paths in v1.111.0) with the same components and the same patch:
six children (cilium-lb, cilium-gateway, cert-manager-install,
cert-manager-selfsigned, cnpg-operator, reloader), all
`kind: OCIRepository`, and every path exists in the tag.

## 5. Bootstrap Flux

blueprints/flux **v3.6.1** or newer: its defaults are flux-operator **0.61.0**
and Flux **2.9.6** (blueprints#209). Older module versions default to
operator 0.47.0, which overrides the 0.61.0 in the helm repo's
`cicd/flux-operator.yaml.gotmpl` (helm#167).

**Merge this directory to `main` first.** The FluxInstance syncs
`refs/heads/main`, and a path that exists only on a branch leaves
`kustomization/flux-system` failing with `path not found`
(homerun2-dev step 4 has the whole story).

```bash
export SOPS_AGE_KEY=...  AGE_PUB=...  GITHUB_USER=...  GITHUB_TOKEN=...

env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/flux@v3.6.1 \
  bootstrap \
  --kube-config file://$HOME/.kube/edge-tt-test1 \
  --deploy-operator=true \
  --commit-to-git=true \
  --repository stuttgart-things/harvester \
  --destination-path "clusters/edge" \
  --git-username env:GITHUB_USER \
  --git-password env:GITHUB_TOKEN \
  --git-token env:GITHUB_TOKEN \
  --sops-age-key env:SOPS_AGE_KEY \
  --age-public-key env:AGE_PUB \
  --render-secrets=true \
  --apply-secrets=true \
  --apply-config=true \
  --encrypt-secrets=true \
  --helmfile-ref "git::https://github.com/stuttgart-things/helm.git@cicd/flux-operator.yaml.gotmpl" \
  --wait-for-reconciliation=true \
  --progress plain
```

`env -u SSH_AUTH_SOCK`: a stale agent socket (e.g. a closed VS Code remote
session) makes Dagger fail while loading the module with `failed to list SSH
agent identities`.

Afterwards:

- Pull the committed `config.yaml` and `secrets.yaml`, and add the two
  `# pragma: allowlist secret` hand-edits (homerun2-dev step 4).
- `config.yaml` syncs `clusters/edge` from **Git** (this repo). Only the
  *content* comes from the flux OCI artifact. Making the root an OCI artifact
  as well (`spec.sync.kind: OCIRepository`) is the step after this one, and it
  only matters once the box runs offline.

[`kustomization.yaml`](./kustomization.yaml) lists `config.yaml` and
`secrets.yaml`, so it does not build until the bootstrap has committed them.

## 6. Verify

```bash
flux get sources oci -A                       # flux-repo READY, v1.111.0@sha256:...
flux get ks -A                                # edge-infra -> infra-platform + 6 children; edge-apps -> homerun2(-routes), homerun2-notify, tabletennis + inner ones
kubectl get gateway -A                        # edge-gateway PROGRAMMED, address = the LB VIP
kubectl -n default get certificate wildcard-tls
kubectl -n homerun2 get pods
kubectl -n schmetterpause get cluster,pods    # CNPG schmetterpause-db, 1 instance
curl -k https://schmetterpause.edge-tt-test1.4sthings.tiab.ssc.sva.de/
```

Expected order: redis-stack takes about 70s before it answers. homerun2 waits
for it, the routes wait for homerun2, and tabletennis waits for homerun2 and
cnpg-operator.

## Footprint

This is an estimate, not a measurement: about 2.5-4Gi in use for everything
above, on 8Gi. **Measure it on the VM** (`kubectl top pods -A`,
`free -m` on the node) before trimming anything. Likely trims, in order:

1. redis-stack: replica + sentinel off. This needs a values patch on the
   HelmRelease (the profile has no variable for it), and the clients' Redis
   address has to be checked, because the service name changes without
   sentinel.
2. homerun2 `profiles/base` + add-ons instead of `profiles/sops`: drop scout,
   config-viewer and demo-pitcher.

## Moving to the hardware

Same directory, same artifact. What changes:

- **OS:** install Ubuntu on the eMMC by hand, then run `sthings.baseos.setup`
  against it (the VM got that from its request). After that, follow
  [`k3s/`](./k3s/) with the box's address in `inventory.ini`.
- **Address:** a static address or DHCP reservation for the node (Cilium
  `k8sServiceHost`, see step 3), and one more free address for the LB VIP in
  `infra/infra-platform.yaml`.
- **Lab CA:** `sthings.baseos.setup` installs the lab Vault CAs only from
  instances it can reach. On the edge it finds none and skips them; that is
  not an error.

### DNS on the edge

On the hardware, `*.<domain>` has to resolve to the LB VIP on every client. With no
router of our own, the options in order of effort: `/etc/hosts` entries on the
few clients, a dnsmasq on the uplink router if there is one, or nip.io
(`INFRA_DOMAIN: <vip>.nip.io`, which needs internet on the client). The
wildcard certificate is self-signed, so clients either trust `cluster-ca`
(`kubectl -n cert-manager get secret cluster-ca-secret -o jsonpath='{.data.ca\.crt}'`)
or accept the warning. schmetterpause's session cookie is `Secure`, so it
needs HTTPS, but a certificate the client merely accepts is enough.

### Still online

Everything below still comes from the internet at install or reconcile time:
OS packages, the k3s binary, cilium-cli, Gateway API CRDs, and **every image
and chart** (ghcr.io, quay.io, docker.io, jetstack, cnpg). The box needs
internet while it is set up and whenever Flux reconciles something new.
Running fully offline is a separate step:

- the role's air-gap vars (`k3s_airgapped_*`, `cilium_airgapped_*`)
- a registry on the node with k3s `registries.yaml` mirrors
- the flux artifact mirrored into it
- `spec.sync` of the FluxInstance switched to OCI
