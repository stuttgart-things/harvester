# clusters/edge

A single-node **k3s** cluster for the edge box, a LattePanda Mu (Intel N100,
8GB LPDDR5, 64GB eMMC). It runs only occasionally, and when it runs it has to
manage with **only that one node**: no OpenBao, no NFS, no lab DNS, no S3, no
Rancher. It is built on a lab VM of the same shape first (`vms/edge.*`), then
on the hardware.

The chain: Ansible (base OS + k3s + Cilium) → Flux Operator → the infra bundle
→ homerun2 → tabletennis. Everything Flux reconciles comes from **one OCI
artifact** of `stuttgart-things/flux` ([`flux-sources.yaml`](./flux-sources.yaml)),
not from Git.

> **Status: draft, not built yet.** Two values are placeholders: the LB address
> in [`infra-platform.yaml`](./infra-platform.yaml), and `vms/edge.params.enc.yaml`,
> which does not exist yet.

| | |
|---|---|
| Cluster / VM name | `edge` |
| Shape | 4 vCPU / 8Gi / 64Gi (VM) = N100 / 8GB / 64GB eMMC (hardware) |
| LB address | **TODO**: one address, the Cilium VIP of the Gateway |
| Domain | `edge.sthings.lab` |
| Kubernetes | k3s `v1.35.9+k3s1` on sqlite/kine, Cilium 1.20.2 (cilium-cli 0.20.1, Gateway API v1.6.1), no kube-proxy, no flannel, no traefik, no servicelb |
| Storage | k3s `local-path` (the default class). Nothing here is meant to survive the box. |
| Certificates | cert-manager, self-signed root → `cluster-ca` → `*.edge.sthings.lab` |
| Secrets | SOPS only: [`edge-secrets-subst.enc.yaml`](./edge-secrets-subst.enc.yaml), decrypted by Flux |
| GitOps | Flux Operator, syncing `clusters/edge`; content from `oci://ghcr.io/stuttgart-things/flux/repo` |

```bash
export KUBECONFIG=~/.kube/harvester
export SOPS_AGE_KEY=...          # the repo's age key
export GITHUB_USER=... GITHUB_TOKEN=... AGE_PUB=...
```

---

## What runs here, and what deliberately does not

| Layer | Selected | Left out, and why |
|---|---|---|
| Ansible | `sthings.baseos.setup`, `sthings.rke.k3s_cluster` | the `k3s` play (ingress-nginx + a cert-manager that wants `root-ca`); `k3s_arm` (installs no Cilium, so the node would have no CNI) |
| infra bundle | `cilium-lb`, `cilium-gateway`, `cert-manager-install`, `cert-manager-selfsigned`, `cnpg-operator`, `reloader` | vault issuer, ESO, sops-git, nfs-csi, coredns-lab-zone, velero, trust-manager, openebs, headlamp, flux-web. Each is explained in `infra-platform.yaml` |
| homerun2 | `profiles/sops` + `sops-routes`, as on homerun2-dev | `redis-lb` (nothing off the node reads Redis); the Teams webhook (notification-catcher stays in dry run) |
| tabletennis | `profiles/sops` + `zaehlwerk-panel-homerun2` | DB backup (no S3); scoreboard + handover (would need the self-signed CA in zaehlwerk's trust) |

## 1. Address and name

**Lab VM:** reserve one address in Clusterbook with the wildcard
`*.edge.sthings.lab`, exactly as in
[`../homerun2-dev/README.md`](../homerun2-dev/README.md) step 1. Then put it into
`CILIUM_LB_IP_START`/`STOP` in `infra-platform.yaml`.

**Edge box:** there is no Clusterbook and no lab router. Pick a free address
in the edge network for the VIP and change the same two values. See
[DNS on the edge](#dns-on-the-edge).

## 2. VM credentials (lab VM only)

`vms/edge.params.enc.yaml` holds the same keys as `vms/edge.params.yaml`, plus
`cloudInitUsername`, `cloudInitPassword` and `cloudInitSshKey`. Create it the
way `vms/machinery-hv.params.enc.yaml` was created: copy the plaintext file,
add the three keys, then
`sops --encrypt --age $AGE_PUB --in-place vms/edge.params.enc.yaml`.

## 3. VM, base OS, k3s, Cilium

```bash
export ANSIBLE_USER=$(sops -d --extract '["cloudInitUsername"]' ./vms/edge.params.enc.yaml)
export ANSIBLE_PASSWORD=$(sops -d --extract '["cloudInitPassword"]' ./vms/edge.params.enc.yaml)

# DRY RUN FIRST
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.2 \
  render-harvester-vm --kcl-parameters-file ./vms/edge.params.yaml contents

dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.2 \
  bake-harvester \
  --kube-config file://$HOME/.kube/harvester \
  --vm-name edge \
  --namespace default \
  --encrypted-file ./vms/edge.params.enc.yaml \
  --sops-key env:SOPS_AGE_KEY \
  --ansible-playbooks "sthings.baseos.setup,sthings.rke.k3s_cluster" \
  --ansible-parameters "manage_filesystem=false install_k3s=true k3s_state=present k3s_k8s_version=1.35.9 k3s_release_kind=k3s1 k3s_cluster_init=false cluster_setup=singlenode cluster_name=edge install_cilium=true cilium_version=0.20.1 cilium_chart_version=1.20.2 cilium_gateway_api_crds_version=v1.6.1 prepare_rancher_ha_nodes=true install_helm_diff=false fetched_kubeconfig_path=/tmp/kubeconfig" \
  --requirements-data https://raw.githubusercontent.com/stuttgart-things/harvester/refs/heads/main/vms/edge.requirements-data.yaml \
  --inventory-type cluster \
  --ansible-user env:ANSIBLE_USER \
  --ansible-password env:ANSIBLE_PASSWORD \
  --progress plain -vv \
  export --path /tmp/edge
```

**`--requirements-data` is not optional.** Without it, `bake-harvester` installs
the collections pinned in stuttgart-things/ansible `templates/requirements-data.yaml`.
That file does not read this repo's `requirements.yaml`, and as of 2026-10-03
it still points at sthings-rke 26.730.1176. That collection silently ignores
`cilium_chart_version` and `k3s_cluster_init`: the run goes green with the
cli-default Cilium and embedded etcd.
[`vms/edge.requirements-data.yaml`](../../vms/edge.requirements-data.yaml) pins
sthings-rke 26.1003.1399 (deploy-configure-rke 2026.10.03-1). It is read from
`main`, so it only takes effect once this directory is merged.

The traps from homerun2-dev step 2 apply unchanged: `--inventory-type cluster`
is required, playbooks are comma-separated and parameters space-separated,
`manage_filesystem=false`, and a green run is not proof (require a
`PLAY RECAP`). Two things are different on k3s:

- There is no `rke2_cni=none` / `disableKubeProxy`. The role's `k3s_config`
  defaults already disable flannel, kube-proxy, network policy, servicelb and
  traefik, and `install_cilium=true` installs Cilium with Gateway API, L2
  announcements and externalIPs.
- Cilium's `k8sServiceHost` is the node's **default IPv4 at install time**. On
  the edge box that address must not change afterwards (static address or DHCP
  reservation), or Cilium loses the API server.

Verify, from the exported kubeconfig (see homerun2-dev step 3 for getting it
off the node):

```bash
kubectl get nodes -o wide                     # one node, v1.35.9+k3s1
kubectl -n kube-system get ds                 # cilium, cilium-envoy; no kube-proxy
cilium version                                # cilium image (running): v1.20.2
kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'   # v1.6.1
ssh <node> sudo ls /var/lib/rancher/k3s/server/db   # state.db (sqlite), no etcd/
kubectl get storageclass                      # local-path (default)
```

## 4. The flux artifact

[`flux-sources.yaml`](./flux-sources.yaml) reads
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
`infra-platform.yaml` patches that to `OCIRepository`; flux#621 proposes a
`FLUX_SOURCE_KIND` so the patch can go.

Rendered locally at v1.110.3 (identical for these paths in v1.111.0) with the same components and the same patch:
six children (cilium-lb, cilium-gateway, cert-manager-install,
cert-manager-selfsigned, cnpg-operator, reloader), all
`kind: OCIRepository`, and every path exists in the tag.

## 5. Bootstrap Flux

The same call as [homerun2-dev step 4](../homerun2-dev/README.md#4-bootstrap-flux),
with `--kube-config` pointing at this cluster,
`--destination-path "clusters/edge"`, and `--branch-name` set while this
directory exists only on a branch. Afterwards:

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
flux get ks -A                                # infra-platform, its 6 children, homerun2(-routes), tabletennis + inner ones
kubectl get gateway -A                        # edge-gateway PROGRAMMED, address = the LB VIP
kubectl -n default get certificate wildcard-tls
kubectl -n homerun2 get pods
kubectl -n schmetterpause get cluster,pods    # CNPG schmetterpause-db, 1 instance
curl -k https://schmetterpause.edge.sthings.lab/
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

- **OS:** install Ubuntu on the eMMC by hand (the golden image is
  Harvester-only). Then run the same two playbooks, using `execute-ansible`
  against the box's address instead of `bake-harvester`, with the same
  `--requirements-data` and `--parameters-file ./vms/edge.k3s.ansible-vars.yaml`.
- **Address:** a static address or DHCP reservation for the node (Cilium
  `k8sServiceHost`, see step 3), and one more free address for the LB VIP in
  `infra-platform.yaml`.
- **Lab CA:** `sthings.baseos.setup` installs the lab Vault CAs only from
  instances it can reach. On the edge it finds none and skips them; that is
  not an error.

### DNS on the edge

`*.edge.sthings.lab` has to resolve to the LB VIP on every client. With no
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
