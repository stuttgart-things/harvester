# clusters/edge/terraform/openbao

Configuration of the OpenBao on the edge node (deployed by Flux,
[`../../apps/openbao.yaml`](../../apps/openbao.yaml)): a PKI with an
intermediate "(openbao)" under the persistent edge root, and **ACME** so that
devices (ESP32) enrol themselves (harvester#364, phase 3). Flux never reads
this directory.

```
stuttgart-things edge root CA            clusters/edge/edge-root-ca.crt (key offline, secrets/edge/root-ca.enc.yaml)
├── intermediate (cert-manager)          ClusterIssuer edge-ca -- the Gateway wildcard
└── intermediate (openbao)               this: key generated INSIDE OpenBao, CSR signed offline
    └── devices                          role `devices`, ACME, key_type any
```

| | |
|---|---|
| Terraform | mount `pki` (ACME headers), cluster/AIA URLs, role `devices` (subdomains of `acme_allowed_domains`, `key_type any`, server+client auth, 90d / max 1y), ACME config (`eab_policy`, `dns_resolver`) |
| [`sign-intermediate.sh`](./sign-intermediate.sh) | the intermediate: OpenBao generates key + CSR, the CSR is signed **offline** with the root, the certificate is imported. Refuses to run if the mount already has an issuer. |
| State | `backend "kubernetes"`, Secret `openbao/tfstate-default-openbao-edge`. **No private key in it.** |
| Login | userpass user `terraform` (policy: PKI at `pki/` only), password `OPENBAO_TERRAFORM_PASSWORD` in `secrets/edge/app-values.enc.yaml`. OpenBao creates the user itself on first start (self-init, flux `components/self-init-userpass`); no root token exists. Break-glass: user `admin`, `OPENBAO_ADMIN_PASSWORD`, by hand only. |

## Order, once per install

OpenBao initialises **itself** on its first start (self-init: userpass with
`terraform` and `admin`, no root token, no recovery keys) and unseals itself
with the static seal on every start. There is no `bao operator init` step.

```bash
cd ~/projects/harvester
export KUBECONFIG=~/.kube/edge-tt-test1

# 1. Terraform: mount, URLs, role, ACME -- logged in as `terraform`
umask 077
sops -d --extract '["stringData"]["OPENBAO_TERRAFORM_PASSWORD"]' secrets/edge/app-values.enc.yaml \
  | jq -Rs '{openbao_password: rtrimstr("\n")}' > /tmp/edge-openbao.tfvars.json
printf 'nameserver 10.100.136.115\nnameserver 10.100.101.5\n' > /tmp/edge-resolv.conf
ENV=lab   # or box: env/<ENV>.auto.tfvars.json -- address, ACME domains, DNS resolver
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/dagger/terraform@v0.136.0 \
  execute --terraform-dir clusters/edge/terraform/openbao --operation apply --refuse-destroy \
  --extra-files clusters/edge/edge-root-ca.crt,clusters/edge/terraform/openbao/env/$ENV.auto.tfvars.json \
  --secret-json-variables file:///tmp/edge-openbao.tfvars.json \
  --kube-config file://$HOME/.kube/edge-tt-test1 --resolv-conf /tmp/edge-resolv.conf --progress plain

# 2. the intermediate -- logs in as `terraform` by itself; refuses (fail
#    closed) when the mount already has an issuer
OPENBAO_ADDR=https://openbao.edge-tt-test1.4sthings.tiab.ssc.sva.de \
  clusters/edge/terraform/openbao/sign-intermediate.sh
shred -u /tmp/edge-openbao.tfvars.json
```

ACME directory: `https://openbao.<domain>/v1/pki/acme/directory` (or
`…/v1/pki/roles/devices/acme/directory`). Clients must trust
`clusters/edge/edge-root-ca.crt`.

## Per environment

| | `env/lab.auto.tfvars.json` | `env/box.auto.tfvars.json` |
|---|---|---|
| `openbao_addr` | `https://openbao.edge-tt-test1.4sthings.tiab.ssc.sva.de` | `https://openbao.edge.sthings.lab` |
| `acme_allowed_domains` | `edge-tt-test1.4sthings.tiab.ssc.sva.de` (Clusterbook wildcard) | `edge.sthings.lab` (OpenWrt names the devices) |
| `acme_dns_resolver` | empty: the cluster DNS (with the lab zone forward) | the OpenWrt router, `<ip>:53` -- **`OPENWRT_LAN_IP` is a placeholder** until the router exists; OpenBao rejects it, so the box run fails loudly instead of validating against the wrong DNS |

Passed with `--extra-files`; there are no defaults, so a run without an
environment file fails. Checked 2026-10-05 on the lab with v0.136.0: `No
changes` (the file reproduces exactly what was applied before).

## Device validation (open)

ACME validates by connecting to the device name (http-01, tls-alpn-01) or by
looking up a TXT record (dns-01). OpenBao must resolve the device names.
`acme_dns_resolver` points that at a DNS server of the edge network once
devices are named there. Until then only names the cluster DNS knows can
validate.

## Last run

2026-10-04, on `edge-tt-test1`:

| Step | Result |
|---|---|
| `bao operator init` (recovery 1/1) | initialized, unsealed (static seal), pod 1/1. Token + recovery key in `secrets/edge/openbao-init.enc.yaml` |
| Terraform: dagger/terraform v0.135.0, `--resolv-conf`, `--refuse-destroy` | `Apply complete! Resources: 5 added` (mount, cluster, urls, role `devices`, ACME) |
| `sign-intermediate.sh` | intermediate "(openbao)" EC P-256, until 2031-10-04, `openssl verify` against the root: OK; imported, default issuer with a chain of 2 |
| `pki/issue/devices` (EC, 24h) | verifies against `edge-root-ca.crt` via the intermediate; EKU server + client auth |
| `evil.example.com` | `common name evil.example.com not allowed by this role` |
| **ACME, HTTP-01** (lego v4.35.2 as a Job in the cluster, own HTTPRoute on the `http` listener, `LEGO_CA_CERTIFICATES` = edge root) | account created, `The server validated our request`, `Server responded with a certificate`. OpenBao resolved `acmetest.<domain>` through the cluster DNS (wildcard → VIP) and reached it through the Gateway. |

`pki/issue/devices` without `key_type` fails with `role key type "any" not
allowed … without providing key_type`. That is expected: `issue` generates
the key server-side and needs a type. ACME sends a CSR and is not affected.

## Self-init and the lab instance (2026-10-05)

`edge-tt-test1`'s OpenBao was initialised by hand on 2026-10-04, before
self-init existed; self-init only runs on empty storage, so there the same
userpass users and policies (`terraform`, `admin`, texts from flux
`self-init.hcl`) were created once with the old root token. Terraform as
`terraform` then planned **No changes**. `secrets/edge/openbao-init.enc.yaml`
(root token + recovery key) belongs to that instance only and goes away with
the lab rebuild.

**`sign-intermediate.sh` guard, fixed 2026-10-05:** the first version checked
for an existing issuer with a GET on `pki/issuers`, which OpenBao answers with
405 -- read as "no issuer", so a rerun created a **second** intermediate next
to the working one (not made default). It was deleted (issuer + key, default
unchanged, ACME re-enrolment checked); the check now uses LIST and fails
closed on anything but 200/404.

## Break-glass admin

```bash
umask 077
sops -d --extract '["stringData"]["OPENBAO_ADMIN_PASSWORD"]' secrets/edge/app-values.enc.yaml \
  | jq -Rs '{password: rtrimstr("\n")}' \
  | curl -sS --cacert clusters/edge/edge-root-ca.crt -X POST -H 'Content-Type: application/json' --data @- \
      https://openbao.<domain>/v1/auth/userpass/login/admin | jq -r .auth.client_token   # 30 min token, policy `admin` (everything)
```

For the exceptional operation only (enable another auth method, extend a
policy, rotate a password via `auth/userpass/users/<user>/password`, then update <!-- pragma: allowlist secret -->
SOPS). Never in automation. Audit devices cannot be enabled over the API in
OpenBao (config only).
