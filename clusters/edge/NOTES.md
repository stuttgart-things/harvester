# clusters/edge -- notes

Background and history for [README.md](./README.md): why things are the way
they are, and what was measured. Nothing here is needed to run or recreate the
cluster.

## Four things the layers need (learned 2026-10-03/04)

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

## Why the whole flux repo as one artifact

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

## Lab: the emulated ESP and the CoreDNS forward

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

## Backups: the first immediate backup

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
