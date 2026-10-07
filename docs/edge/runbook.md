# Edge cluster -- runbook

How to build an edge cluster -- a lab VM or the box -- **all in one**: every
step in order, and who creates which file. New to it? Use [step by
step](./step-by-step.md), which splits the same work into phases with a commit
and a check after each. General: the values of a concrete cluster live in its
folder (`clusters/edge` = `edge-tt-test1`, LabDA; `clusters/edge-test2` =
`edge-tt-test2`, labul). Every hand-written file with its content:
[from-scratch.md](./from-scratch.md); the picture:
[architecture.md](./architecture.md).

## Layout of a cluster folder: who creates what

```
clusters/<cluster>/
├── cluster-apps.yaml     DEV    what the cluster is: source, layers, apps + their vars/secret refs
├── cluster-vars.yaml     DEV    what differs between environments (EDGE_* values)
├── kustomization.yaml    GEN    what flux-system applies (wiring)
├── .sourceignore         DEV    keeps k3s/, terraform/, cluster-apps.yaml away from Flux
├── config.yaml           BOOT   FluxInstance            (committed by the Flux bootstrap)
├── secrets.yaml          BOOT   git + sops-age secrets  (committed by the Flux bootstrap)
├── apps.yaml             GEN    OCIRepository flux-repo + layers edge-infra / edge-apps / edge-lab
├── cluster-secrets/      GEN    the apps' secrets (SOPS, flux-system) + escrowed cluster key
├── infra/
│   ├── kustomization.yaml  GEN  wiring (+ ca.yaml from spec.layers.edge-infra.extraResources)
│   ├── infra-platform.yaml GEN  the infra bundle
│   ├── ca.yaml             DEV  Kustomization edge-ca -> ./ca
│   └── ca/edge-ca.enc.yaml DEV  the intermediate (SOPS, made once -- see architecture.md, The edge CA)
├── apps/
│   ├── kustomization.yaml  GEN  wiring
│   └── apps-platform.yaml  GEN  the apps bundle
├── lab/                  DEV    LAB VMs ONLY: players' route, ESP mock (+ lab-specific parts)
├── edge-root-ca.crt      DEV    the public root (a copy; made once)
└── k3s/                  DEV    Ansible inventory + vars + requirements -- not Flux

clusters/edge/terraform/  DEV    MinIO + OpenBao config, shared; env/<env>.auto.tfvars.json per environment -- not Flux

secrets/edge/ (repo root, never read by Flux; shared by every edge cluster)
├── app-values.enc.yaml   DEV    the apps' secret values -- ref+sops source for cluster-apps.yaml, input of terraform/*
├── openbao-seal.enc.yaml DEV    OpenBao's static seal key -- MUST NEVER CHANGE once used
├── root-ca.enc.yaml      DEV    root key + all intermediate keys, offline
└── kubeconfig-<node>.enc.yaml  DEV  each cluster's admin kubeconfig (step 3; whole file encrypted)
```

**DEV** = written by hand ([from-scratch.md](./from-scratch.md)).
**GEN** = `render-cluster-apps` output, never edited by hand: change
`cluster-apps.yaml`, re-render ([step 5](#5-flux-files)), commit. A re-render
without changes reproduces the files byte for byte, and every secret value is
a `ref+sops` into `secrets/edge/`, so nothing rotates. **BOOT** = committed by
the Flux bootstrap.

Three layers: `edge-infra` (wait) → `edge-apps` and `edge-lab`. Every layer
substitutes `${EDGE_*}` from the ConfigMap `cluster-vars`, so environments
differ only in `cluster-vars.yaml` and in whether `edge-lab` exists. Why the
layers look like this: [notes.md](./notes.md).

## Recreate from scratch

```bash
export CLUSTER=edge-test2                 # the folder: clusters/$CLUSTER
export KUBECONFIG=~/.kube/edge-tt-test2   # written in step 3
export SOPS_AGE_KEY=...                   # the repo's age key (master)
export AGE_PUB=$(age-keygen -y <<<"$SOPS_AGE_KEY")
export GITHUB_USER=... GITHUB_TOKEN=...
```

| # | Step | Tool | Developer writes | Generated / changed |
|---|---|---|---|---|
| 1 | Address + DNS | Clusterbook (lab) / router (box), Hetzner DNS | `cluster-vars.yaml` | reservations, DNS records |
| 2 | VM + base OS | Backstage `create-vm` / `request-vm` | -- | VM with `sthings.baseos.setup` |
| 3 | k3s + Cilium ([k3s.md](./k3s.md)) | Ansible CLI or blueprints/vm `execute-ansible-with-export` | `k3s/*` | node, kubeconfig |
| 4 | Persistent secrets (**once ever**) | openssl, sops | `secrets/edge/*`, `edge-root-ca.crt`, `infra/ca/edge-ca.enc.yaml` | -- |
| 5 | Flux files | blueprints/flux `render-cluster-apps` | `cluster-apps.yaml`, `infra/ca.yaml`, `.sourceignore`, `lab/` | `apps.yaml`, `*-platform.yaml`, `cluster-secrets/`, the `kustomization.yaml` wiring |
| 6 | Flux | blueprints/flux `bootstrap` | 2 `pragma` comments | `config.yaml`, `secrets.yaml` (committed) |
| 7 | OpenBao init | **nothing to do**: self-init on first start | -- | userpass users `terraform` + `admin` |
| 8 | OpenBao + MinIO config | dagger/terraform, `sign-intermediate.sh` | env files | PKI/ACME, bucket + user |
| 9 | Lab-specific extras | e.g. a lab Vault issuer | -- | -- |
| 10 | Verify | kubectl, curl | -- | -- |

### 1. Address and DNS

Two addresses on the node's network: the **Gateway VIP** (internal names
`*.EDGE_DOMAIN`) and the **players' VIP** (public names `*.EDGE_PLAY_DOMAIN`).
Write them into `clusters/$CLUSTER/cluster-vars.yaml`
([from-scratch.md](./from-scratch.md), 2.1).

**Lab: Clusterbook.** Either you already know two free addresses, or ask
Clusterbook -- with a) curl or b) Dagger. `reserve` with an `ip` claims it
**only if free** (`409` otherwise) and never overwrites; `assign` overwrites a
holder and withdraws its DNS record -- use it only on purpose.

| Lab | Clusterbook | Network | DNS zone |
|---|---|---|---|
| LabDA | `clusterbook.sthings-infra.4sthings.tiab.ssc.sva.de` | `10.100.136` | `4sthings.tiab.ssc.sva.de` |
| labul | `clusterbook.infra.sthings-vsphere.labul.sva.de` | `10.31.102` | `sthings-vsphere.labul.sva.de` |

```bash
CB=clusterbook.infra.sthings-vsphere.labul.sva.de; NET=10.31.102   # labul
NAME=edge-tt-test2; GW_IP=$NET.7; PLAY_IP=$NET.8

# a) curl
curl -s http://$CB/api/v1/networks/$NET/ips \
  | jq -r '.[] | [.ip, (if .status=="" then "free" else .status end), .cluster] | @tsv'
curl -s -X POST http://$CB/api/v1/networks/$NET/reserve -H 'Content-Type: application/json' \
  -d "{\"cluster\":\"$NAME\",\"status\":\"ASSIGNED\",\"create_dns\":true,\"ip\":\"$GW_IP\"}"
curl -s -X POST http://$CB/api/v1/networks/$NET/reserve -H 'Content-Type: application/json' \
  -d "{\"cluster\":\"$NAME-play\",\"status\":\"ASSIGNED\",\"create_dns\":false,\"ip\":\"$PLAY_IP\"}"
#    (leave out "ip" to get the next free one)

# b) Dagger (github.com/stuttgart-things/dagger/clusterbook)
M=github.com/stuttgart-things/dagger/clusterbook@v0.136.0
env -u SSH_AUTH_SOCK dagger call -m $M get-network-ips --server $CB:80 --network-key $NET \
  | jq -r '.[] | [.ip, (if .status=="" then "free" else .status end), .cluster] | @tsv'
env -u SSH_AUTH_SOCK dagger call -m $M reserve-ip --server $CB:80 --network-key $NET --cluster $NAME --create-dns   # next free
env -u SSH_AUTH_SOCK dagger call -m $M assign-ip --server $CB:80 --network-key $NET \
  --ip $GW_IP --cluster $NAME --status ASSIGNED --create-dns                                                    # a SPECIFIC one -- overwrites!
env -u SSH_AUTH_SOCK dagger call -m $M get-cluster --server $CB:80 --cluster-name $NAME

# check from the node -- a workstation in another lab may not resolve this lab's zones
ssh sthings@<node> "dig +short schmetterpause.$NAME.sthings-vsphere.labul.sva.de"   # = GW_IP
```

**Box:** the router's dnsmasq ([architecture.md](./architecture.md), *DNS
commands*).

**Public players' name:** a record in the Hetzner zone `sthings-edge.com`
(`*` → the players' VIP, or `*.<sub>` per lab cluster, e.g. `*.test2`);
cert-manager gets the wildcard from Let's Encrypt via DNS-01. API commands:
[architecture.md](./architecture.md), *Public: Hetzner DNS*.

### 2. VM + base OS

Lab: a Backstage template (`create-vm` with use case `baseos`: Crossplane
`NativeProxmoxVM` on machinery, stuttgart-things#3474; or `request-vm`: Dapr
worker + Terraform, stuttgart-things#3415). The order's AnsibleRun applies
`sthings.baseos.setup`. Nothing in this repo builds the VM. Box: Ubuntu on the
eMMC by hand, then `sthings.baseos.setup` ([Moving to the hardware](#moving-to-the-hardware)).

A DHCP address that belonged to another VM before: `ssh-keygen -R <ip>` and
compare the new host key with the console.

### 3. k3s + Cilium

**[k3s.md](./k3s.md)** -- the three files of `clusters/$CLUSTER/k3s/`
(inventory, vars, collections) as `cat <<EOF` blocks, what the role sets up,
both deployment options (1: Ansible CLI, the kubeconfig lands on your machine; 2: Dagger
`execute-ansible-with-export`, the kubeconfig is exported from the container),
the checks and what a second run changes. Result: node Ready
(v1.35.9+k3s1, sqlite), Cilium 1.20.2 with Gateway API v1.6.1,
`local-path`, the CLIs on the node (k9s, flux, sops, age -- [Tools on the
node](./k3s.md#tools-on-the-node)), the kubeconfig in `$KUBECONFIG` -- and encrypted in
`secrets/edge/kubeconfig-<node>.enc.yaml` ([SOPS + age](../sops.md)).

### 4. Persistent secrets -- once ever

**Skip this when they exist** -- a second edge cluster reuses them. Every
file with its content, the value generators and the SOPS encryption:
[from-scratch.md](./from-scratch.md), section 1. They make a reinstall, another
cluster or the move to the box invisible to clients and devices: same root,
same seal key, same passwords.

### 5. Flux files

The hand-written files ([from-scratch.md](./from-scratch.md), section 2), then:

```bash
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/flux@v3.10.0 \
  render-cluster-apps \
  --cluster-apps clusters/$CLUSTER/cluster-apps.yaml \
  --master-age-key env:SOPS_AGE_KEY \
  --escrow-recipients "$AGE_PUB" \
  --sops-ref-dir . \
  --existing-secrets clusters/$CLUSTER/cluster-secrets \
  export --path /tmp/$CLUSTER-gen
cp -r /tmp/$CLUSTER-gen/flux/. clusters/$CLUSTER/ && rm -rf /tmp/$CLUSTER-gen
```

Without Dagger: write the same files by hand ([from-scratch.md,
2B](./from-scratch.md#2b-flux-files-by-hand)) instead of `cluster-apps.yaml`.

**Leave out `--existing-secrets` on the very first render** (there is no
`cluster-secrets/` yet). The wiring (`kustomization.yaml` at the root, in
`infra/` and `apps/`) is generated too (`spec.wiring`); hand-written files are
listed there as `extraResources`. **Merge to `main`**: the FluxInstance syncs
`refs/heads/main`, and a path that only exists on a branch leaves `flux-system`
at `path not found`.

Later, to move to a newer flux release: bump `spec.source.tag` in
`cluster-apps.yaml` and re-render.

### 6. Flux

blueprints/flux v3.6.1 or newer (flux-operator 0.61.0, Flux 2.9.6):

```bash
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/flux@v3.10.0 \
  bootstrap \
  --kube-config file://$KUBECONFIG \
  --deploy-operator=true \
  --commit-to-git=true \
  --repository stuttgart-things/harvester \
  --destination-path "clusters/$CLUSTER" \
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
  --wait-for-reconciliation=true \
  --progress plain
```

It commits `config.yaml` and `secrets.yaml`; pull them and add the two
`# pragma: allowlist secret` comments. `env -u SSH_AUTH_SOCK`: a stale agent
socket makes Dagger fail with `failed to list SSH agent identities`.
`edge-infra` is Ready after about 8 minutes; homerun2 takes about 7 more
(redis-stack).

### 7. OpenBao init -- nothing to do

OpenBao initialises itself on its first start (`OPENBAO_INIT:
self-init-userpass`, flux#640): userpass with `terraform` (PKI only, for
step 8) and `admin` (break-glass, by hand only), passwords from
`secrets/edge/app-values.enc.yaml`. No root token, no recovery keys; the
static seal unseals every start. If self-init fails (e.g. a password
missing), the server refuses to unseal: fix the secret, then delete PVC
`data-openbao-0` and the pod. Details:
[`clusters/edge/terraform/openbao`](https://github.com/stuttgart-things/harvester/blob/main/clusters/edge/terraform/openbao/README.md).

### 8. OpenBao + MinIO configuration

Both with dagger/terraform v0.136.0+, state in the cluster (`kubernetes`
backend), `--extra-files <cluster>/edge-root-ca.crt,<root>/env/<env>.auto.tfvars.json`
-- the environment file holds the addresses (and, for OpenBao, the ACME
domains and DNS resolver; [from-scratch.md](./from-scratch.md), section 3);
there are no defaults:
[terraform/openbao](https://github.com/stuttgart-things/harvester/blob/main/clusters/edge/terraform/openbao/README.md) (PKI
mount, role `devices`, ACME), then `terraform/openbao/sign-intermediate.sh`
(key generated inside OpenBao, CSR signed with the offline root; refuses if
the mount already has an issuer), and
[terraform/minio](https://github.com/stuttgart-things/harvester/blob/main/clusters/edge/terraform/minio/README.md) (bucket
`schmetterpause-cnpg`, user + policy for the backups). Until MinIO is
configured, schmetterpause's WAL archiving retries.

### 9. Lab-specific extras

Whatever only one lab needs, documented in that cluster's README -- e.g.
`edge-tt-test1`'s Vault issuer on the LabDA Vault and its CoreDNS forward for
the LabDA zone ([`clusters/edge/README.md`](https://github.com/stuttgart-things/harvester/blob/main/clusters/edge/README.md)).

### 10. Verify

```bash
flux get sources oci -A                       # flux-repo READY
flux get ks -A                                # all Ready
kubectl get gateway -A                        # edge-gateway + edge-play-gateway PROGRAMMED on their VIPs
kubectl -n schmetterpause get cluster schmetterpause-db \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].message}'
curl --cacert clusters/$CLUSTER/edge-root-ca.crt https://schmetterpause.<EDGE_DOMAIN>/
curl --cacert clusters/$CLUSTER/edge-root-ca.crt https://openbao.<EDGE_DOMAIN>/v1/pki/acme/directory
curl https://schmetterpause.<EDGE_PLAY_DOMAIN>/          # publicly trusted (Let's Encrypt)
```

The first `immediate` CNPG backup of a fresh rollout fails (the plugin is not
registered yet); start a manual one, see [notes.md](./notes.md). The backup
protects against database mistakes, **not** against losing the node: an
off-box copy is still open (harvester#364). The device path and the apps:
[lab-testing.md](./lab-testing.md).

## Moving to the hardware

Same artifact, same persistent secrets, its own cluster folder. What changes:

- **`cluster-apps.yaml`:** no `edge-lab` layer (and no `lab/`); re-render.
- **`cluster-vars.yaml`:** the box's VIPs and domain (`edge.sthings.lab`).
- **Own SOPS key:** the box decrypts with its own cluster key
  (`cluster-secrets/sops-age.enc.yaml`, escrowed for the master key), not with
  the master key. Get it with
  `dagger call -m github.com/stuttgart-things/blueprints/secrets cluster-age-key --existing clusters/$CLUSTER/cluster-secrets --master-age-key env:SOPS_AGE_KEY plaintext`
  and bootstrap with it as `--sops-age-key`. Hand-encrypted files the box
  decrypts (`infra/ca/edge-ca.enc.yaml`) must be encrypted for that key too
  (`sops updatekeys`). Keep `--escrow-recipients` so the master key can still
  read everything.
- **OS:** Ubuntu on the eMMC by hand, then `sthings.baseos.setup`, then k3s
  with the box's address. A static lease for the node (Cilium
  `k8sServiceHost`), plus free addresses for the VIPs.
- **Terraform:** `env/box.auto.tfvars.json` (OpenBao `acme_dns_resolver` = the
  router).
- **Steps 2 (VM) and 9 do not apply**; 7 and 8 run as on any new instance.

### DNS on the edge

`*.<domain>` has to resolve to the VIP on every client: the router's dnsmasq
(`edge.sthings.lab`, `local=/edge.sthings.lab/`, static leases, the public
players' names answered locally) -- [architecture.md](./architecture.md).
Until the router is set up: `/etc/hosts` on the few clients.

### Still online

OS packages, the k3s binary, cilium-cli, Gateway API CRDs, and **every image
and chart** come from the internet at install or reconcile time. Fully offline
is a separate step: the role's air-gap vars (`k3s_airgapped_*`,
`cilium_airgapped_*`), a registry on the node with k3s `registries.yaml`
mirrors, the flux artifact mirrored into it, and the FluxInstance's
`spec.sync` switched to OCI.
