# SECRETS


```bash
dagger call -m github.com/stuttgart-things/dagger/sops@v0.82.1 decrypt   --age-key env:SOPS_AGE_KEY   --encrypted-file ../secrets/xplane.yaml   export --path=/home/sthings/.kube/xplane
```