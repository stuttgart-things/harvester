# clusters/edge

A single-node **k3s** cluster for the edge box, a LattePanda Mu (Intel N100,
8GB LPDDR5, 64GB eMMC). It runs only occasionally, and when it runs it has to
manage with **only that one node**: no central OpenBao, NFS, lab DNS, S3 or
Rancher. It is tested on a lab VM first (`edge-tt-test1`, LabDA), then built
on the hardware.

The chain: VM + base OS (Backstage request) → k3s + Cilium ([`k3s/`](./k3s/))
→ Flux Operator → the infra bundle
→ homerun2 → tabletennis. Everything Flux reconciles comes from **one OCI
artifact** of `stuttgart-things/flux` ([`sources.yaml`](./sources.yaml)),
not from Git.

> **Status: running on the lab test node since 2026-10-03 11:30 UTC.** All 25
> Kustomizations Ready, apps reachable through the Gateway VIP. See
> [First rollout](#first-rollout-2026-10-03). Next: the LattePanda.

| | |
|---|---|
| Cluster | `edge` |
| Test node | `edge-tt-test1` / 10.100.136.89 (LabDA vSphere, 8 vCPU / 15Gi / 128Gi) |
| Target | LattePanda Mu: N100 / 8GB / 64GB eMMC |
| LB address | `10.100.136.223` (LabDA Clusterbook, `edge-tt-test1`), the Cilium VIP of the Gateway |
| Domain | `edge-tt-test1.4sthings.tiab.ssc.sva.de` (Clusterbook DNS wildcard) for the lab test; changes on the hardware |
| Kubernetes | k3s `v1.35.9+k3s1` on sqlite/kine, Cilium 1.20.2 (cilium-cli 0.20.1, Gateway API v1.6.1), no kube-proxy, no flannel, no traefik, no servicelb |
| Storage | k3s `local-path` (the default class). Nothing here is meant to survive the box. |
| Certificates | cert-manager, ClusterIssuer `edge-ca`: the **persistent** edge root → intermediate → `*.<INFRA_DOMAIN>` ([The edge CA](#the-edge-ca)) |
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
├── kustomization.yaml   flux-system applies only: config, secrets, cluster-vars, sources, infra.yaml, apps.yaml
├── cluster-vars.yaml    ConfigMap: what differs between lab and LattePanda (EDGE_DOMAIN, EDGE_LB_IP, EDGE_GATEWAY_NAME, EDGE_CLUSTER_NAME)
├── config.yaml  secrets.yaml        FluxInstance + git/sops secrets (committed by the bootstrap)
├── sources.yaml         OCIRepository flux-repo -> ghcr.io/stuttgart-things/flux/repo
├── infra.yaml           Kustomization edge-infra -> ./infra   (wait: true)
├── apps.yaml            Kustomization edge-apps  -> ./apps    (dependsOn edge-infra)
├── infra/               infra-platform.yaml: the flux infra bundle
├── apps/                homerun2, tabletennis, edge-secrets-subst (SOPS),
│   └── minio.yaml         MinIO on the node: S3 for the schmetterpause backups
└── k3s/                 Ansible for k3s + Cilium -- never read by Flux (.sourceignore)
```

Two layers, so the apps start only once the whole infra bundle is Ready, and
can be stopped or removed without touching it (`flux suspend ks edge-apps`).

**Lab vs. LattePanda: one file.** `infra/` and `apps/` carry `${EDGE_*}`
placeholders, not values. Both layers substitute them from the ConfigMap
`cluster-vars` ([`cluster-vars.yaml`](./cluster-vars.yaml)), so the
environments differ only in that file. Consequence: no object these two layers
apply may carry any other `${...}`, because the layer's substitution would
replace it with an empty string. Values meant for a child Kustomization stay in
that child's own `postBuild` (they are plain strings in this repo).

### Three things the layers need, learned on 2026-10-03

1. **Every layer that applies a `*.enc.yaml` needs its own `decryption`
   block.** The FluxInstance's sops patch (`config.yaml`,
   `kustomize.patches`) reaches only the Kustomization the instance itself
   creates, `flux-system`, not the ones applied from git. Before the split,
   `flux-system` applied `edge-secrets-subst.enc.yaml`. After it, `edge-apps`
   applied the file still encrypted, and the dry-run failed with
   `no matches for kind "ENC[AES256_GCM,...]"` (fixed in #360).
   `apps.yaml` carries the block; `infra.yaml` needs none as long as `./infra`
   has no SOPS file.

2. **An object in a namespace that an app creates cannot sit in the same
   layer apply.** `homerun2-notification-catcher-notify` lives in `homerun2`,
   which only exists after the `homerun2` Kustomization has run. Listed in
   `apps/kustomization.yaml`, it would fail the `edge-apps` apply on a fresh
   cluster, and with it the `homerun2` Kustomization it is supposed to
   create: a deadlock. The fix is to render it **inside the app's own build**,
   next to its namespace: homerun2 selects the flux component `notify-none`,
   and tabletennis selects `schmetterpause-db-backup-subst` for its backup
   Secret (flux #627, #628). Until 2026-10-04 both were separate
   Kustomizations with a retry; the openbao seal Secret still is one
   (`openbao-prereqs`), because it must exist before the HelmRelease.

3. **Moving Kustomizations between layers rebuilds them.** When `#359` moved
   `infra-platform`, `homerun2` and `tabletennis` from `flux-system` into
   `edge-infra` / `edge-apps`, `flux-system` pruned them. Their own
   `prune: true` took the infra namespaces (cert-manager, cnpg-system,
   reloader) and all of homerun2 with them, and the layers recreated them.
   On this fresh test node that was intended: 11:13 merge, infra Ready again
   about 8 minutes later. On a node that matters, set
   `kustomize.toolkit.fluxcd.io/prune: disabled` on the moving objects first.

4. **Never introduce a layer's substitution and its placeholders in the same
   merge.** With cluster-vars (#373), `edge-infra` reconciled the new
   `infra-platform.yaml` (with `${EDGE_*}`) **before** `flux-system` had applied
   its new spec with `substituteFrom`. infra-platform received the literal
   `${EDGE_DOMAIN}`. cert-manager re-issued the wildcard as `*.${EDGE_DOMAIN}`,
   and cilium-gateway tried a Gateway named `${EDGE_GATEWAY_NAME}`, which the
   dry-run rejected. HTTPS failed until the values were patched back by hand.
   Next time: first add `substituteFrom` to the layer, merge, then the
   placeholders. Or suspend the layer during the merge. A **new**
   Kustomization that carries `substituteFrom` from its first apply (like
   `edge-lab`) is not affected.

## The edge CA

One root for everything on the box: the gateway wildcard now, and the OpenBao
ACME issuer for the ESP32 devices later (harvester#364, phase 3). It is
**persistent**: generated once (2026-10-03) and kept in git, so a reinstall,
or the move to the LattePanda, does not change what clients and devices
trust.

| | Where | |
|---|---|---|
| Root CA, public | [`edge-root-ca.crt`](./edge-root-ca.crt) | `O=stuttgart-things, CN=stuttgart-things edge root CA`, EC P-384, valid until 2046-10-03. **This is what clients and devices trust.** |
| Root key + all intermediate keys | `secrets/edge-root-ca.enc.yaml` (repo root, SOPS) | **offline**: outside every Flux path, never in the cluster. Only needed to sign a new intermediate. |
| Intermediate "(cert-manager)" | [`infra/ca/edge-ca.enc.yaml`](./infra/ca/edge-ca.enc.yaml) (SOPS) | EC P-256, 5 years (until 2031-10-03), `pathlen:0`. Secret `cert-manager/edge-ca`: `tls.crt` = intermediate + root, `ca.crt` = root. |
| Issuer | flux component `cert-manager-ca-from-secret` in [`infra/infra-platform.yaml`](./infra/infra-platform.yaml) | ClusterIssuer `edge-ca` reading Secret `cert-manager/edge-ca`; `CERT_MANAGER_SELFSIGNED_ISSUER: edge-ca` makes the gateway wildcard come from it |

The self-signed `cluster-ca` from `cert-manager-selfsigned` still exists. It is
regenerated per install, and nothing that clients see uses it any more.

```bash
# trust it on a client
sudo cp clusters/edge/edge-root-ca.crt /usr/local/share/ca-certificates/edge-root-ca.crt && sudo update-ca-certificates
# check the chain the gateway serves
openssl s_client -connect <VIP>:443 -servername schmetterpause.<domain> -showcerts </dev/null | grep -E "s:|i:"
```

**A new intermediate** (OpenBao in phase 3, or a rotation) is signed with the
root from `secrets/edge-root-ca.enc.yaml`. Decrypt it only locally, into a
scratch directory, and shred it afterwards. The new intermediate key goes
SOPS-encrypted next to the existing ones; the root key never leaves that file.

## Lab only: the Vault issuer and the players' Gateway

The edge's public side (deSEC name + Let's Encrypt, harvester#364) does not
exist in the lab. [`lab.yaml`](./lab.yaml) → [`lab/`](./lab/) stands in for it,
and the LattePanda does not get it:

| | |
|---|---|
| ClusterIssuer `vault-pki-4sthings` | the LabDA Vault (`https://vault-vsphere.tiab.labda.sva.de:8200`, `pki/sign/4sthings.tiab.ssc.sva.de`), via k8s auth, as on sthings-platform and the other LabDA clusters |
| Gateway `edge-play-gateway` | its own VIP `EDGE_PLAY_LB_IP` (10.100.136.226, Clusterbook `edge-tt-test1-play` with DNS), wildcard `*.EDGE_PLAY_DOMAIN` from that Vault |
| HTTPRoute `schmetterpause-play` | `https://schmetterpause.edge-tt-test1-play.4sthings.tiab.ssc.sva.de` → the same Service |

The Vault side was created once, imperatively, as for every LabDA cluster:

```bash
# the k8s auth mount edge-tt-test1-certmanager on the LabDA Vault + the Secret
# cert-manager/vault-pki-ca (the Vault's PKI CA). The kubeconfig and the Vault
# env are SOPS files (the env: stuttgart-things secrets/envs/vault-labda.enc.yaml).
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/argocd@v3.6.2 \
  create-vault-kubernetes-auth \
  --cluster-name edge-tt-test1 \
  --kubeconfig-source-file <kubeconfig.enc.yaml> \
  --vault-env-file <vault-labda.enc.yaml> --sops-key env:SOPS_AGE_KEY \
  --auth-name certmanager --namespace cert-manager \
  --bound-service-account-names cert-manager --bound-service-account-namespaces cert-manager \
  --token-policies pki-issue-4sthings --token-ttl 3600 \
  --ca-secret-name vault-pki-ca
```

`pki-issue-4sthings` is the policy that the other LabDA mounts
(`sthings-platform-certmanager`, `labda-dev-a-certmanager`, ...) bind; read
from the Vault on 2026-10-04. `vault-pki-ca` and the reviewer SA
`cert-manager/certmanager` are not Flux objects. If the cert-manager namespace
is ever rebuilt, run the call again.

**The emulated ESP** ([`lab/esp-mock`](./lab/esp-mock/), #375) is the zaehlwerk
piezo board mock with a device certificate from OpenBao. A lego init container
enrols via ACME HTTP-01 for `piezo-a.<EDGE_DOMAIN>`. The board then plays
matches against `https://zaehlwerk.<EDGE_DOMAIN>` and trusts only the edge
root. Checked on 2026-10-04: "The server validated our request … Server
responded with a certificate", then `rally … points` every 3 s.

**The LabDA zone needs its own forward in CoreDNS**
([`lab/coredns-lab-zone.yaml`](./lab/coredns-lab-zone.yaml), k3s
`coredns-custom`). The node lists two resolvers, and only 10.100.136.115 knows
`4sthings.tiab.ssc.sva.de`. CoreDNS picked one at random, so names under the
Clusterbook wildcard SERVFAILed from pods every other time. The mock's first
HTTPS call timed out, and the ACME validation took 2 minutes. With the forward:
20/20 lookups OK.

## What runs here, and what deliberately does not

| Layer | Selected | Left out, and why |
|---|---|---|
| Ansible | `sthings.baseos.setup`, `sthings.rke.k3s_cluster` | the `k3s` play (ingress-nginx + a cert-manager that wants `root-ca`); `k3s_arm` (installs no Cilium, so the node would have no CNI) |
| infra bundle | `cilium-lb`, `cilium-gateway`, `cert-manager-install`, `cert-manager-selfsigned`, `cnpg-operator`, `cnpg-barman-cloud`, `reloader` | vault issuer, ESO, sops-git, nfs-csi, coredns-lab-zone, velero, trust-manager, openebs, headlamp, flux-web. Each is explained in `infra/infra-platform.yaml` |
| homerun2 | `profiles/sops` + `sops-routes`, as on homerun2-dev | `redis-lb` (nothing off the node reads Redis); the Teams webhook (notification-catcher stays in dry run) |
| tabletennis | `profiles/sops` + `zaehlwerk-panel-homerun2` + `schmetterpause-db-backup-sops` (WAL archive + daily base backup, 7d, into MinIO on the node) | scoreboard + handover (would need the self-signed CA in zaehlwerk's trust) |
| MinIO | `apps/minio` (chart 16.0.10) + HTTPRoute, bucket `schmetterpause-cnpg` via `defaultBuckets`, 5Gi local-path | an off-box copy: the backup protects against DB mistakes, **not** against losing the node (harvester#364) |

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
flux get sources oci -A                       # flux-repo READY, v1.116.0@sha256:...
flux get ks -A                                # edge-infra -> infra-platform + 6 children; edge-apps -> homerun2(-routes), minio(-httproute), openbao(-prereqs, -httproute), tabletennis + inner ones
kubectl get gateway -A                        # edge-gateway PROGRAMMED, address = the LB VIP
kubectl -n default get certificate wildcard-tls
kubectl -n homerun2 get pods
kubectl -n schmetterpause get cluster,pods    # CNPG schmetterpause-db, 1 instance
curl -k https://schmetterpause.edge-tt-test1.4sthings.tiab.ssc.sva.de/
```

Expected order: `edge-infra` (the whole bundle) → `edge-apps` → homerun2.
redis-stack takes about 70s before it answers, and the catchers restart until it
does. The routes wait for homerun2, and tabletennis
waits for homerun2 and cnpg-operator.

### Backups (schmetterpause → MinIO on the node)

```bash
kubectl -n schmetterpause get cluster schmetterpause-db \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].message}'   # Continuous archiving is working
kubectl -n schmetterpause get backups.postgresql.cnpg.io                         # daily at 03:00, PHASE completed
```

**The first `immediate` backup fails on a fresh rollout** with `requested
plugin is not available: barman-cloud.cloudnative-pg.io`. The ScheduledBackup
fires as soon as tabletennis applies, before the Barman Cloud plugin has
registered with the CNPG operator. WAL archiving is not affected. Delete the
failed Backup and, to have a base backup right away, start one:

```bash
kubectl -n schmetterpause apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: {name: schmetterpause-db-manual, namespace: schmetterpause}
spec:
  cluster: {name: schmetterpause-db}
  method: plugin
  pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}
EOF
```

Seen on 2026-10-03 (#365): the immediate one failed after 18s, and a manual
one 3 minutes later completed. The bucket and its credentials move to
Terraform next (harvester#364, phase 1b).

## First rollout: 2026-10-03

On `edge-tt-test1` (LabDA, 8 vCPU / 15Gi), with flux/repo v1.111.0,
blueprints/flux v3.6.1 (flux-operator 0.61.0, Flux 2.9.6), k3s v1.35.9+k3s1,
and Cilium 1.20.2.

| Time (UTC) | |
|---|---|
| 10:27 to 10:33 | k3s + Cilium (Ansible CLI, [`k3s/`](./k3s/)) |
| 10:59 | Flux bootstrap (3m52s), commit `6348f3d` |
| 11:13 | infra/apps split merged (#359); the moved Kustomizations are pruned and rebuilt |
| 11:21 | sops decryption on `edge-apps` (#360) |
| **11:30** | **all 25 Kustomizations Ready** |

| Check | Result |
|---|---|
| Gateway | `edge-gateway` PROGRAMMED, address `10.100.136.223` (Cilium L2) |
| TLS | `wildcard-tls` Ready, `CN=*.edge-tt-test1.4sthings.tiab.ssc.sva.de`, issuer `cluster-ca` |
| Routes | 11 HTTPRoutes (8 homerun2, 2 schmetterpause, 1 zaehlwerk) |
| schmetterpause | https **200**, http **301** → https |
| zaehlwerk | https 302 |
| omni-pitcher | `/health` **200** |
| Postgres | CNPG `schmetterpause-db` 1/1, "Cluster in healthy state" |
| Pods | 31/31 Running |
| Versions | schmetterpause v0.14.0, zaehlwerk v0.9.0, light-catcher v1.5.0, notification-catcher v3.0.2, redis chart 17.1.4 |

**UFW does not get in the way.** baseos leaves UFW active without 80/tcp, but
the Gateway is reachable on 80 and 443. Cilium's eBPF kube-proxy replacement
handles the VIP traffic before netfilter's INPUT chain sees it.

**Redis is the slow start.** redis-stack takes 3-4 minutes to 2/2 (Sentinel last).
core-catcher, omni-pitcher and scout restart until it answers. homerun2 is
Ready about 7 minutes after `edge-apps` starts.

## Footprint

Measured 2026-10-03 after the rollout, everything above running:

| | |
|---|---|
| Node memory used (`free -m`, OS included) | **~3.0 GiB** (12.5 GiB available on the 15 GiB VM) |
| Workloads (`kubectl top node`) | 2.1 GiB, 383m CPU (4%) |
| Largest pods | cilium 171Mi, flux-operator 86Mi, kustomize-controller 70Mi, cilium-operator 58Mi, Postgres 53Mi, led-catcher 50Mi |
| `/var/lib/rancher/k3s` | 6.1 GB (images + sqlite + local-path) |

**That fits the LattePanda's 8 GB RAM / 64 GB eMMC without trimming.** The
earlier estimate was 2.5-4 GiB. Trims stay available if the box gets more
apps:

1. redis-stack: replica + sentinel off. This needs a values patch on the
   HelmRelease, because the profile has no variable for it, and the clients'
   Redis address changes without sentinel.
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
