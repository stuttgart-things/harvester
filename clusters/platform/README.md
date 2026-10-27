# PLATFORM.STHINGS.LAB

## OpenBao — the PKI this environment is moving to

The `sthings.lab` PKI is moving off the Vault on the `infra` cluster (which is
being switched off to free the hardware) onto an **OpenBao** on this cluster,
with cert-manager ordering certificates through **Kubernetes auth** instead of a
long-lived token.

**The steps that a human has to run — `bao operator init`, Terraform, revoking
the root token — are in [`openbao/README.md`](openbao/README.md).** Flux does
not and cannot do them.

| | |
|---|---|
| Deployment | `apps-platform.yaml` — the `apps/platform` bundle, component `../components/openbao` |
| Seal | `static`, key in `apps/openbao-static-seal.enc.yaml` |
| PKI / auth config | `openbao/` — Terraform via `vault-base-setup` |
| Runbook | [`openbao/README.md`](openbao/README.md) |
| Rehearsed on | `cicd-test3` — `stuttgart-things/clusters/labda/vsphere/cicd-test3/OPENBAO.md` |

> The new root CA is trusted by **nothing** until it is distributed — Ansible for
> VMs, Flux/Argo for clusters, across the whole harvester environment. Until
> that lands, certificates signed by it are valid and rejected everywhere. Only
> then does the `infra` Vault come down.

## ZITADEL — the lab IdP for sthings-portal

`https://zitadel.platform.sthings.lab` (#560, as in the vSphere labs since
stuttgart-things/stuttgart-things#4118).

| | |
|---|---|
| Deployment | `apps-platform.yaml`, component `../components/zitadel` (PostgreSQL on `local-path`) |
| Secrets | `apps/zitadel-secrets.enc.yaml` (Secret `zitadel-secrets`): `ZITADEL_MASTERKEY` -- **never changes**, it decrypts the data in PostgreSQL -- DB passwords, initial admin password |
| Admin | `zitadel-admin@zitadel.zitadel.platform.sthings.lab`, password `ZITADEL_ADMIN_PASSWORD` (`sops -d`), changed at the first login |
| Terraform | [`zitadel-config/`](zitadel-config/README.md): project, roles, the homerun2-dev portal's OIDC client, users |
| Backup | none yet -- `pg_dump` plus the masterkey |

<details open>
<summary>OS-PREREQUISITES FOR ANSIBLE</summary>

```bash
ssh-copy-id sthings@platform.sthings.lab
ssh sthings@platform.sthings.lab

sudo cat /etc/sudoers
#....
# ...
Defaults env_reset
#Defaults use_pty

sthings ALL=(ALL) NOPASSWD: ALL

@includedir /etc/sudoers.d


sudo apt -y install python3.13-venv
sudo python3 -m venv /opt/k3s-venv
sudo chown -R sthings:sthings /opt/k3s-venv

/opt/k3s-venv/bin/python3 -m ensurepip
/opt/k3s-venv/bin/python3 -m pip install --upgrade pip setuptools wheel packaging

/opt/k3s-venv/bin/pip list
/opt/k3s-venv/bin/python3 -c "import packaging; print(packaging.__version__)"
```

</details>

<details open>
<summary>CREATE K3S CLUSTER + UPLOAD ENCRYPTED KUBECONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v1.70.0 \
execute-ansible-encrypt-and-commit \
--playbooks "sthings.rke.k3s_cluster" \
--hosts platform.sthings.lab \
--ssh-user=env:SSH_USER \
--ssh-password=env:SSH_PASSWORD \
--requirements=../../requirements.yaml \
--parameters "cilium_version=0.19.0 k3s_k8s_version=1.35.9 k3s_release_kind=k3s1 cluster_setup=singlenode fetched_kubeconfig_path=/tmp/k3s.yaml install_k3s=true k3s_state=present prepare_rancher_ha_nodes=true" \
--inventory-type cluster \
--age-public-key=env:AGE_PUB \
--export-paths "/tmp/k3s.yaml" \
--progress plain -vv \
--git-repository "stuttgart-things/harvester" \
--git-create-pr=true \
--git-pr-title="add platform cluster" \
--git-branch main \
--git-commit-message "Add encrypted kubeconfig for k3s cluster infra" \
--git-destination-path "secrets" \
--export-target-names=platform.sthings.lab.yaml \
--git-token=env:GITHUB_TOKEN \
--progress plain -vv
```

</details>

<details open>
<summary>UPGRADE K3S IN PLACE</summary>

Use `execute-ansible`, not the create call above. The role only re-runs the k3s
install script (which replaces the binary and restarts k3s) when the version or
the k3s config differs, so a version bump is the upgrade. The rendered
`/etc/rancher/k3s/k3s-config.yaml` matches the live file, and `registries.yaml`
(Harbor mirror, added by hand) is not touched without `k3s_registry_mirrors`.

**`install_cilium=false` is mandatory here.** With it on, the role runs
`cilium upgrade -f <its current template>`. On this cluster that would:

- move the IPAM pool from `10.0.0.0/8` to `10.42.0.0/16` while the node holds
  `10.0.0.0/24`;
- set the image pullPolicy to `Always`.

None of that belongs in a k8s patch. Cilium stays at 1.18.5 (cilium-cli 0.19.0,
from the 2026-03-16 build) until that is planned on its own.

Gateway ALPN and appProtocol are on since 2026-10-27 (ZITADEL needs `h2` on the
TLS listener and h2c to its backend). Only these two values were changed on the
Helm release, nothing else:

```bash
helm upgrade cilium cilium --repo https://helm.cilium.io --version 1.18.5 \
  -n kube-system --reuse-values \
  --set gatewayAPI.enableAlpn=true --set gatewayAPI.enableAppProtocol=true
```

All routes answered the same before and after (now over HTTP/2). The operator
logs a burst of `no kind is registered for the type v1alpha2.TLSRouteList` at
start: there is no TLSRoute CRD here, harmless.

```bash
dagger call -m github.com/stuttgart-things/blueprints/vm@v3.2.2 \
  execute-ansible \
  --playbooks "sthings.rke.k3s_cluster" \
  --hosts platform.sthings.lab \
  --inventory-type cluster \
  --parameters "cilium_version=0.19.0 install_cilium=false k3s_k8s_version=1.35.9 k3s_release_kind=k3s1 cluster_setup=singlenode fetched_kubeconfig_path=/tmp/k3s.yaml install_k3s=true k3s_state=present prepare_rancher_ha_nodes=true" \
  --ssh-user env:SSH_USER \
  --ssh-password env:SSH_PASSWORD \
  --cache-buster "upgrade-$(date +%s)" \
  --progress plain
```

Everything on the lab's hub is down while k3s restarts: Rancher, OpenBao,
ArgoCD, Harbor and Backstage. OpenBao unseals itself (static seal). Afterwards,
check that the cilium-operator started its Gateway API controller. If it came
up while the apiserver was unreachable, it logs `Required GatewayAPI resources
are not found`, and new HTTPRoutes stay without status until
`kubectl -n kube-system rollout restart deploy/cilium-operator`.

Last upgrade: `2026-10-23`, `v1.35.1+k3s1` -> `v1.35.9+k3s1` (#491).
`ok=100 changed=14 unreachable=0 failed=0 skipped=64` in 14 min. Afterwards:

- node `Ready` on v1.35.9, Cilium unchanged (1.18.5, pool `10.0.0.0/8`);
- all Kustomizations/HelmReleases Ready after ~10 min (harbor's Helm upgrade
  and a briefly unreachable CNPG webhook took the longest);
- 11/11 HTTPRoutes Accepted, gateway controller started;
- OpenBao unsealed, and harvester, app-dev-hv and tabletennis Ready in Rancher.

</details>

<details open>
<summary>DECRYPT + TEST KUBECONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/dagger/sops@v0.85.0 decrypt \
  --age-key env:SOPS_AGE_KEY \
  --encrypted-file ../../secrets/platform.sthings.lab.yaml \
  export --path=/home/sthings/.kube/platform.sthings.lab
```

```bash
export KUBECONFIG=/home/sthings/.kube/platform.sthings.lab
kubectl get nodes
```

</details>

<details open>
<summary>FLUX INIT + CILIUM CONFIG</summary>

```bash
dagger call -m github.com/stuttgart-things/blueprints/kubernetes-deployment@v1.70.0 \
flux-bootstrap \
--kube-config file:///home/sthings/.kube/platform.sthings.lab \
--deploy-operator=true \
--commit-to-git=true \
--repository stuttgart-things/harvester \
--destination-path "clusters/platform" \
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
--operator-version "0.42.1" \
--wait-for-reconciliation=true \
--progress plain
```

</details>

<details open>
<summary>DNS ENTRY</summary>

```bash
address=/platform.sthings.lab/192.168.10.160
```

</details>

<details open>
<summary>CILIUM CONFIG+CERT-MANAGER+DNS</summary>

```bash
# APPLY GIT REPOS
cat <<EOF | kubectl apply -f -
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-infra
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  url: https://github.com/stuttgart-things/flux.git
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-apps
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  url: https://github.com/stuttgart-things/flux.git
EOF
```

</details>

<details open>
<summary>CREATE CILIUM CONFIG</summary>






</details>
