# Edge cluster -- step by step

A new edge cluster in **phases you can commit and test one at a time**. Each
phase lists what you write, the command or commands to run, **one commit**, and a
**check** that has to pass before you go on. If a check fails, the problem is
in that phase.

The same procedure in one go, for those who know it:
[runbook](./runbook.md) (*Recreate from scratch*, all in one). The file
contents: [from scratch](./from-scratch.md). The picture:
[architecture](./architecture.md).

Most steps can be done two ways:

| | CLI | Dagger |
|---|---|---|
| Encrypt/decrypt secrets | `sops` + `age` | `dagger/sops` (`encrypt --encrypted-regex`, `decrypt --extract`, `set`, `update-keys`) |
| k3s + Cilium | `ansible-playbook` | `blueprints/vm execute-ansible-with-export` |
| Flux files | written by hand (`cat <<EOF`, [option B](#option-b-by-hand)) | `ClusterApps` + `blueprints/flux render-cluster-apps` ([option A](#option-a-clusterapps-render-cluster-apps)) |
| Flux bootstrap | -- | `blueprints/flux bootstrap` |
| OpenBao + MinIO config | -- | `dagger/terraform` |

What to install for either way: [Workstation setup](../workstation.md).

## Before you start

```bash
export CLUSTER=edge-test2                     # the folder: clusters/$CLUSTER
export NODE=edge-tt-test2                     # the VM's name
export KUBECONFIG=~/.kube/$NODE               # written in phase 2
export SOPS_AGE_KEY=$(cat ~/.config/sops/age/keys.txt)
export AGE_PUB=$(age-keygen -y <<<"$SOPS_AGE_KEY")
export GITHUB_USER=... GITHUB_TOKEN=...       # phase 5

git switch -c feat/$CLUSTER                   # one branch, a commit per phase
```

**Git:** commit and push to your branch after each phase. Nothing reads the
branch before phase 5, so commit as often as you like. **Merge to `main` before
phase 5**, because the Flux bootstrap points the cluster at `refs/heads/main`.

**Check (prerequisites):**

```bash
sops --version; age --version; dagger version; docker info >/dev/null && echo docker ok
sops -d secrets/edge/app-values.enc.yaml >/dev/null && echo "age key ok"    # if secrets/edge/ exists
```

## Phase 1: Persistent secrets -- once ever

**Skip it if `secrets/edge/` already exists**: every edge cluster shares these
files.

**Write:** the edge CA, the OpenBao seal key and the app values ([from
scratch, section 1](./from-scratch.md#1-persistent-secrets)). Encrypt them with the
`enc` helper, which comes as a sops CLI version and a Dagger version
([section 0](./from-scratch.md#0-the-age-key)).

**Commit:**

```bash
git add secrets/edge/ && git commit -m "feat(edge): persistent secrets (CA, OpenBao seal key, app values)"
```

**Check:** every file decrypts, and the app values are complete:

```bash
for f in secrets/edge/*.enc.yaml; do sops -d "$f" >/dev/null && echo "ok $f"; done
sops -d secrets/edge/app-values.enc.yaml | yq '.stringData | keys | length'     # 20
git show --stat HEAD | grep -v '\.enc\.yaml' | grep 'secrets/'                  # empty: no plaintext committed
```

## Phase 2: The node -- address, VM, k3s

**Write:** `clusters/$CLUSTER/k3s/` -- inventory, vars, requirements and the
tools list ([k3s.md, The files](./k3s.md)). Then follow the [runbook](./runbook.md):

1. Reserve the address and DNS ([runbook step 1](./runbook.md#1-address-and-dns), curl or Dagger).
2. Create the VM ([step 2](./runbook.md#2-vm-base-os), Backstage).
3. Install k3s with Cilium, using option 1 (Ansible CLI) or option 2 (Dagger)
   ([k3s.md](./k3s.md#deployment-option-1-ansible-cli)).
4. Install the tools on the node ([k3s.md](./k3s.md#tools-on-the-node)).

Encrypt the kubeconfig with the sops CLI or Dagger
([SOPS + age](../sops.md#kubeconfigs-in-the-repo)):

```bash
sops --encrypt --age "$AGE_PUB" --input-type yaml --output-type yaml \
  $KUBECONFIG > secrets/edge/kubeconfig-$NODE.enc.yaml
#   Dagger:
#   env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/dagger/sops@v0.137.0 encrypt \
#     --age-key env:AGE_PUB --plaintext-file $KUBECONFIG export --path secrets/edge/kubeconfig-$NODE.enc.yaml
```

**Commit:**

```bash
git add clusters/$CLUSTER/k3s secrets/edge/kubeconfig-$NODE.enc.yaml
git commit -m "feat($CLUSTER): k3s files, kubeconfig (SOPS)"
```

**Check:** the node is Ready, Cilium and the Gateway API are up, and the
committed kubeconfig works:

```bash
kubectl get nodes                                          # Ready, v1.35.9+k3s1
kubectl -n kube-system get pods                            # cilium*, coredns, ... Running
kubectl get gatewayclass cilium                            # ACCEPTED True
sops -d secrets/edge/kubeconfig-$NODE.enc.yaml | KUBECONFIG=/dev/stdin kubectl get nodes
```

## Phase 3: Cluster files -- what you write by hand

**Write** the following ([from scratch, section 2](./from-scratch.md#2-cluster-files)):

- `cluster-vars.yaml`: the addresses and names;
- `infra/ca.yaml` and `infra/ca/`: the edge CA intermediate;
- `edge-root-ca.crt`;
- `.sourceignore`;
- on lab VMs, `lab/`.

These files are the same whichever way you make the Flux files in phase 4.

**Commit:**

```bash
git add clusters/$CLUSTER && git commit -m "feat($CLUSTER): cluster files (vars, edge CA, lab)"
```

**Check:** every file is valid YAML, and the kustomize folders build:

```bash
yq 'true' clusters/$CLUSTER/cluster-vars.yaml >/dev/null && echo "cluster-vars ok"
yq '.data | keys' clusters/$CLUSTER/cluster-vars.yaml       # EDGE_* -- nothing left as an example value
kubectl kustomize clusters/$CLUSTER/infra/ca >/dev/null && echo "infra/ca ok"
kubectl kustomize clusters/$CLUSTER/lab >/dev/null && echo "lab ok"         # lab VMs only
sops -d clusters/$CLUSTER/infra/ca/edge-ca.enc.yaml | yq '.kind'           # Secret
```

## Phase 4: Flux files

These are the files Flux applies: the source and the layers (`apps.yaml`), the
two bundles, the apps' secrets and the wiring. There are two ways to make them,
and both give the same result (tested on `clusters/edge`: the secrets are equal
after decryption, the objects are the same).

### Option A: ClusterApps + render-cluster-apps

You describe the cluster in **one** file: `cluster-apps.yaml` (`kind:
ClusterApps`, [from scratch 2.2](./from-scratch.md#22-clustersclustercluster-appsyaml)).
That file lists the source, the layers, the apps with their vars, and the
secrets as `ref+sops://` references into `secrets/edge/`. Dagger generates
everything else from it:

```bash
env -u SSH_AUTH_SOCK dagger call -m github.com/stuttgart-things/blueprints/flux@v3.11.0 \
  render-cluster-apps \
  --cluster-apps clusters/$CLUSTER/cluster-apps.yaml \
  --master-age-key env:SOPS_AGE_KEY \
  --escrow-recipients "$AGE_PUB" \
  --sops-ref-dir . \
  export --path /tmp/$CLUSTER-gen
cp -r /tmp/$CLUSTER-gen/flux/. clusters/$CLUSTER/ && rm -rf /tmp/$CLUSTER-gen
```

Every later render adds `--existing-secrets clusters/$CLUSTER/cluster-secrets`,
which keeps unchanged secrets byte for byte. **Good for:** several clusters
from one description, changing an app in one place, and the cluster's own key
with escrow. **Never edit** the generated files: change `cluster-apps.yaml`
and render again.

### Option B: by hand

The same files, written with `cat <<'EOF'` and encrypted with `enc` (sops CLI
or Dagger). You don't need the generator or the `ClusterApps` file, and you can see every object
Flux applies: [from scratch, section 2B](./from-scratch.md#2b-flux-files-by-hand).
**Good for:** learning what the generator does, and repos without Dagger.
Then **you** maintain the files: to add an app, add its component, its vars
and its Secret, and edit the `kustomization.yaml`.

The apps' secrets are encrypted for the master key only. There is no
per-cluster key and no escrow.

**Commit and merge** (either option):

```bash
git add clusters/$CLUSTER && git commit -m "feat($CLUSTER): Flux files"
git push -u origin feat/$CLUSTER     # then a PR, and merge it to main
```

**Check (before the merge):** every layer builds, every secret decrypts, and
there is no plaintext:

```bash
for d in infra apps cluster-secrets/secrets; do
  kubectl kustomize clusters/$CLUSTER/$d >/dev/null && echo "ok $d"; done
kubectl kustomize clusters/$CLUSTER/infra | yq ea '[.metadata.name] | join(" ")'   # edge-ca infra-platform
for f in clusters/$CLUSTER/cluster-secrets/secrets/flux-system/*.enc.yaml; do
  sops -d "$f" | yq '.metadata.name'; done
grep -L 'ENC\[AES256_GCM' clusters/$CLUSTER/cluster-secrets/secrets/flux-system/*.enc.yaml   # empty
yq ea '[.metadata.name] | join(" ")' clusters/$CLUSTER/apps.yaml   # flux-repo edge-apps edge-infra (edge-lab)
```

The root `kustomization.yaml` does not build yet, because it lists
`config.yaml` and `secrets.yaml`. Phase 5 commits those two files.

## Phase 5: Flux bootstrap

The bootstrap installs the Flux operator and its FluxInstance on the cluster
(syncing `clusters/$CLUSTER` on `main`) and creates the Secret `sops-age`. It
also commits `config.yaml` and `secrets.yaml`. The command is in [runbook step
6](./runbook.md#6-flux) (Dagger `blueprints/flux bootstrap`).

**Commit:** the bootstrap has already committed the two files on `main`.
Pull them and add the two `# pragma: allowlist secret` comments:

```bash
git switch main && git pull
# add "# pragma: allowlist secret" to the two flagged lines in secrets.yaml
git commit -am "chore($CLUSTER): pragma comments" && git push
```

**Check:** the source and the layers come up, in order. `edge-infra` takes
about 8 minutes; the apps take about 7 more (redis-stack):

```bash
flux get sources git -A; flux get sources oci -A      # flux-system + flux-repo READY
flux get ks -A                                        # edge-infra, then edge-apps, edge-lab, the apps: Ready
kubectl get gateway -A                                # edge-gateway, edge-play-gateway PROGRAMMED
kubectl get certificate -A                            # wildcard-tls Ready
```

## Phase 6: OpenBao -- self-init

There is nothing to write. On its first start, OpenBao initialises itself with
the users `terraform` and `admin` ([runbook step
7](./runbook.md#7-openbao-init-nothing-to-do)).

**Check:**

```bash
kubectl -n openbao exec openbao-0 -- bao status -format=json | jq -c '{initialized,sealed,type}'
# {"initialized":true,"sealed":false,"type":"static"}
```

## Phase 7: OpenBao + MinIO configuration

**Write:** the environment's address files ([from scratch, section
3](./from-scratch.md#3-terraform-env-files)). Then run Terraform with
`dagger/terraform`: OpenBao (PKI, ACME), `sign-intermediate.sh`, and MinIO
(bucket and user) ([runbook step
8](./runbook.md#8-openbao-minio-configuration)).

**Commit:**

```bash
git add clusters/edge/terraform/*/env/ && git commit -m "feat($CLUSTER): terraform env files"
```

**Check:** the devices' ACME endpoint answers, and the database backups reach
MinIO:

```bash
curl --cacert clusters/$CLUSTER/edge-root-ca.crt https://openbao.$(yq .data.EDGE_DOMAIN clusters/$CLUSTER/cluster-vars.yaml)/v1/pki/acme/directory
kubectl -n schmetterpause get cluster schmetterpause-db \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'   # True
```

## Phase 8: Verify

Run the end-to-end checks from [runbook step 10](./runbook.md#10-verify): the
internal names with the edge CA, and the players' name with Let's Encrypt.
Then test the device path with the ESP mock ([lab testing](./lab-testing.md)).
