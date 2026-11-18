# harbor-config

Projects and registry endpoints of the platform Harbor
(`goharbor/harbor`, [`../apps/goharbor.yaml`](../apps/goharbor.yaml), #693).

| Resource | What |
|---|---|
| `harbor_registry.dockerhub` | Docker Hub endpoint `docker`, anonymous |
| `harbor_project.docker` | public proxy-cache project `docker` |

State: Secret `tfstate-default-harbor-config` in namespace `goharbor` on platform.

## Apply

```bash
export KUBECONFIG=~/.kube/platform.sthings.lab
export SSL_CERT_FILE=$HOME/.config/zitadel/ca-harvester.pem
export TF_VAR_harbor_password="$(kubectl -n goharbor get secret goharbor-secrets \
  -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)"
terraform init
terraform plan
terraform apply
```

Check: `docker pull docker.harbor.platform.sthings.lab/library/nginx`.
