# harbor-config

Projects and registry endpoints of the platform Harbor
(`goharbor/harbor`, [`../apps/goharbor.yaml`](../apps/goharbor.yaml), #693).

| Resource | What |
|---|---|
| `harbor_registry.dockerhub` | Docker Hub endpoint `docker`, anonymous |
| `harbor_project.docker` | public proxy-cache project `docker` |
| `harbor_config_auth.oidc` | OIDC login against ZITADEL (`oidc.tf`), local admin stays |

State: Secret `tfstate-default-harbor-config` in namespace `goharbor` on platform.

## Apply

```bash
export KUBECONFIG=~/.kube/platform.sthings.lab
export SSL_CERT_FILE=$HOME/.config/zitadel/ca-harvester.pem
export TF_VAR_harbor_password="$(kubectl -n goharbor get secret goharbor-secrets \
  -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)"
# OIDC client of ../zitadel-config (apply that first when the app is new):
export TF_VAR_oidc_client_id="$(cd ../zitadel-config && terraform output -json app_client_ids | jq -r .harbor)"
export TF_VAR_oidc_client_secret="$(cd ../zitadel-config && terraform output -json app_client_secrets | jq -r .harbor)"
terraform init
terraform plan
terraform apply
```

Check: `docker pull docker.harbor.platform.sthings.lab/library/nginx`.

## Login

- **ZITADEL**: "LOGIN WITH ZITADEL" on https://harbor.platform.sthings.lab.
  Only users with role `harbor-admin` or `harbor-user` on the ZITADEL
  project `harbor` get through (role check). New users are onboarded with
  their `preferred_username`.
- **Local admin** (break-glass): user `admin`, password in Secret
  `goharbor-secrets` (`HARBOR_ADMIN_PASSWORD`), form on the same page.

## Admins

Harbor cannot map ZITADEL's role map to its admin flag (it reads groups only
from a flat list claim), so `harbor-admin` users are made sysadmin once,
after their first ZITADEL login, with the local admin:

```bash
H=https://harbor.platform.sthings.lab/api/v2.0
for u in sthings indy tommy; do
  id=$(curl -sk -u "admin:$TF_VAR_harbor_password" "$H/users/search?username=$u" \
    | jq -r --arg u "$u" '.[] | select(.username==$u) | .user_id')
  [ -n "$id" ] && curl -sk -u "admin:$TF_VAR_harbor_password" -X PUT \
    -H 'Content-Type: application/json' -d '{"sysadmin_flag":true}' \
    "$H/users/$id/sysadmin" && echo "$u ($id): sysadmin"
done
```

Keep the list in sync with `harbor-admin` in `../zitadel-config/apps.auto.tfvars`.
