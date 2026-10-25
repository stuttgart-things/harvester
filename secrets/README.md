# SECRETS

`harvester.yaml` is the Harvester cluster itself. `.github/workflows/vms-bake.yml`
decrypts it at run time, which is why it is here rather than a GitHub secret:
`SOPS_AGE_KEY` stays the only thing stored outside the repo, so rotating that
key rotates access to every credential the pipeline uses at once.

`homerun2-dev.yaml` is the singlenode RKE2 cluster on the `homerun2-dev` VM
(`192.168.10.117:6443`, v1.35.3+rke2r1) -- see `clusters/homerun2-dev/README.md`
for the whole build.

That address is a static DHCP lease on the router (keyed on the VM's MAC, see
`docs/install.md`), not the cluster's `192.168.10.171` -- the latter is the
Cilium LB VIP reserved in Clusterbook and answers for Services, never for the
API server. A rebuilt VM gets a new MAC: update the lease, or this file points
at nothing. Redo the fetch and re-encrypt when the address changes.

That is not hypothetical. It is how the predecessor ended: `xplane.yaml` held
the kubeconfig for the `bootstrap-xplane` VM at `192.168.10.124`, the VM came
back from a rebuild on `.125`, and the file kept naming the old address -- so
the cluster read as gone (`no route to host`) when only its address had moved.
That VM and that file were retired with `homerun2-dev`; both are still in git
history if they are ever wanted.

Decrypt a SOPS/AGE-encrypted kubeconfig from this directory:

```bash
dagger call -m github.com/stuttgart-things/dagger/sops@v0.85.0 decrypt \
  --age-key env:SOPS_AGE_KEY \
  --encrypted-file ../secrets/homerun2-dev.yaml \
  export --path=/home/sthings/.kube/homerun2-dev
```

## edge/

How to create each of them (content, value generators, SOPS):
`docs/edge/from-scratch.md`, section 1.

The SOPS sources of `clusters/edge` (single-node edge k3s). Never read by Flux;
`docs/edge/runbook.md` ("Layout of a cluster folder", step 4) says what each
holds and how it is made:

- `app-values.enc.yaml` -- the apps' secret values (`ref+sops` source of
  `clusters/edge/cluster-apps.yaml`, input of `clusters/edge/terraform/minio`)
- `openbao-seal.enc.yaml` -- OpenBao's static seal key. **Never change it**: the
  raft data is sealed with it.
- `root-ca.enc.yaml` -- the edge root key + all intermediate keys (offline)
- `openbao-init.enc.yaml` -- root token + recovery key from `bao operator init`
  (only `edge-tt-test1`, initialised by hand)
- `kubeconfig-<node>.enc.yaml` -- each edge cluster's admin kubeconfig (whole
  file encrypted): `edge-tt-test1`, `edge-tt-test2`

SOPS, the age key and encrypting/decrypting (CLI or Dagger): `docs/sops.md`
(https://stuttgart-things.github.io/harvester/docs/sops/).
