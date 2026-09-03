# SECRETS

`harvester.yaml` is the Harvester cluster itself. `.github/workflows/vms-bake.yml`
decrypts it at run time, which is why it is here rather than a GitHub secret:
`SOPS_AGE_KEY` stays the only thing stored outside the repo, so rotating that
key rotates access to every credential the pipeline uses at once.

`xplane.yaml` is the singlenode RKE2 cluster on the `bootstrap-xplane` VM
(`192.168.10.124:6443`, v1.35.3+rke2r1) -- see `vms/README.md` for how it is
built. It replaced a kubeconfig for a predecessor at `192.168.10.106`, which
stopped answering; that version is still in git history if it is ever wanted.

Decrypt a SOPS/AGE-encrypted kubeconfig from this directory:

```bash
dagger call -m github.com/stuttgart-things/dagger/sops@v0.82.1 decrypt \
  --age-key env:SOPS_AGE_KEY \
  --encrypted-file ../secrets/xplane.yaml \
  export --path=/home/sthings/.kube/xplane
```
