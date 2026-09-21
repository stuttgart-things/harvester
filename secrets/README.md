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
