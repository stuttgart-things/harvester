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
| Token | the root token from `bao operator init`, kept SOPS-encrypted in `secrets/edge/openbao-init.enc.yaml` (outside every Flux path) |

## Order, once per install

```bash
cd ~/projects/harvester
export KUBECONFIG=~/.kube/edge-tt-test1

# 1. init -- once; the static seal unseals every restart after that
kubectl -n openbao exec openbao-0 -- bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json \
  > /tmp/openbao-edge-init.json            # root_token + recovery key: SOPS it at once
# -> secrets/edge/openbao-init.enc.yaml (sops --encrypt), shred the plaintext

# 2. Terraform: mount, URLs, role, ACME
umask 077
jq -n --arg t "$(sops -d --extract '["root_token"]' secrets/edge/openbao-init.enc.yaml)" '{openbao_token: $t}' > /tmp/edge-openbao.tfvars.json
printf 'nameserver 10.100.136.115\nnameserver 10.100.101.5\n' > /tmp/edge-resolv.conf
ENV=lab   # or box: env/<ENV>.auto.tfvars.json -- address, ACME domains, DNS resolver
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/dagger/terraform@v0.136.0 \
  execute --terraform-dir clusters/edge/terraform/openbao --operation apply --refuse-destroy \
  --extra-files clusters/edge/edge-root-ca.crt,clusters/edge/terraform/openbao/env/$ENV.auto.tfvars.json \
  --secret-json-variables file:///tmp/edge-openbao.tfvars.json \
  --kube-config file://$HOME/.kube/edge-tt-test1 --resolv-conf /tmp/edge-resolv.conf --progress plain

# 3. the intermediate
OPENBAO_ADDR=https://openbao.edge-tt-test1.4sthings.tiab.ssc.sva.de \
OPENBAO_TOKEN=$(sops -d --extract '["root_token"]' secrets/edge/openbao-init.enc.yaml) \
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
