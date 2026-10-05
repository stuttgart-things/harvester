# Edge cluster from scratch -- every file you write by hand

For a repo **without** an existing edge cluster or its secrets: what to create,
where, under which name, with which content -- as `cat <<'EOF'` blocks to
copy. Everything not listed here is either **generated** (blueprints/flux
`render-cluster-apps`) or **committed by the Flux bootstrap**; see the
runbook in [README.md](./README.md) (*Recreate from scratch*) for the order,
[ARCHITECTURE.md](./ARCHITECTURE.md) for the picture.

| Part | Files | Made with | Once per |
|---|---|---|---|
| [0. The age key](#0-the-age-key) | outside the repo | `age-keygen` | repo / team |
| [1. Persistent secrets](#1-persistent-secrets) | `secrets/edge/*.enc.yaml`, `edge-root-ca.crt`, `infra/ca/edge-ca.enc.yaml` | openssl, sops | **ever** (shared by every edge cluster: lab VMs and box) |
| [2. Cluster files](#2-cluster-files) | `clusters/<cluster>/…` | `cat <<'EOF'` | cluster |
| [3. Terraform env files](#3-terraform-env-files) | `clusters/edge/terraform/*/env/<env>.auto.tfvars.json` | `cat <<'EOF'` | environment |

Conventions in every block below: run from the repo root; plaintext only under
`umask 077` in a temp directory, `shred -u` it afterwards; never `echo` a
secret into a terminal or a log.

## 0. The age key

SOPS encrypts for an age public key. If the team has one, use it (it is the
"master key": every SOPS file in the repo is readable with it):

```bash
export SOPS_AGE_KEY=$(cat ~/.config/sops/age/keys.txt)   # or from your password manager
export AGE_PUB=$(age-keygen -y <<<"$SOPS_AGE_KEY")
```

None yet: `age-keygen -o ~/.config/sops/age/keys.txt` (mode 600), keep a copy
in the team's password manager. Losing it means losing every secret below.

The helper used in all blocks:

```bash
enc() {  # enc <plaintext.yaml> <target.enc.yaml>: encrypt only data/stringData
  sops --encrypt --age "$AGE_PUB" --encrypted-regex '^(data|stringData)$' \
    --input-type yaml --output-type yaml "$1" > "$2" && shred -u "$1"
}
```

## 1. Persistent secrets

**Once ever.** They are what makes a reinstall -- or another cluster, or the
move to the box -- invisible to clients and devices: same root CA, same
OpenBao seal key, same passwords. A second edge cluster **reuses** them
(`clusters/edge-test2` does). Skip any that already exist.

### 1.1 The edge CA

Root (EC P-384, 20 years, key stays offline) and the intermediate for
cert-manager (EC P-256, 5 years, `pathlen:0`). The OpenBao intermediate is
**not** made here: its key is generated inside OpenBao
(`terraform/openbao/sign-intermediate.sh`).

```bash
umask 077; W=$(mktemp -d); cd "$W"

openssl ecparam -name secp384r1 -genkey -noout -out root.key
openssl req -x509 -new -key root.key -sha384 -days 7300 \
  -subj "/O=stuttgart-things/CN=stuttgart-things edge root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" -out root.crt

openssl ecparam -name prime256v1 -genkey -noout -out int.key
openssl req -new -key int.key \
  -subj "/O=stuttgart-things/CN=stuttgart-things edge intermediate CA (cert-manager)" -out int.csr
cat > int.ext <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign,digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
openssl x509 -req -in int.csr -CA root.crt -CAkey root.key -CAcreateserial \
  -sha384 -days 1826 -extfile int.ext -out int.crt
openssl verify -CAfile root.crt int.crt                     # int.crt: OK

cd - >/dev/null
```

Three files from it -- **`secrets/edge/root-ca.enc.yaml`** (root key and every
intermediate key; never applied, `namespace: not-applied`):

```bash
mkdir -p secrets/edge
cat > "$W/root-ca.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: edge-root-ca
  namespace: not-applied
type: Opaque
stringData:
  root.crt: |
$(sed 's/^/    /' "$W/root.crt")
  root.key: |
$(sed 's/^/    /' "$W/root.key")
  intermediate-cert-manager.crt: |
$(sed 's/^/    /' "$W/int.crt")
  intermediate-cert-manager.key: |
$(sed 's/^/    /' "$W/int.key")
EOF
enc "$W/root-ca.yaml" secrets/edge/root-ca.enc.yaml
```

**`clusters/<cluster>/edge-root-ca.crt`** -- the public root, what clients and
devices trust (plaintext, committed; copy it into every edge cluster folder and
into `lab/esp-mock/`):

```bash
cp "$W/root.crt" clusters/edge/edge-root-ca.crt
```

**`clusters/<cluster>/infra/ca/edge-ca.enc.yaml`** -- the intermediate as the
Secret `cert-manager/edge-ca` that the ClusterIssuer `edge-ca` signs with
(`tls.crt` = intermediate + root):

```bash
mkdir -p clusters/edge/infra/ca
cat > "$W/edge-ca.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: edge-ca
  namespace: cert-manager
type: kubernetes.io/tls
stringData:
  tls.crt: |
$(cat "$W/int.crt" "$W/root.crt" | sed 's/^/    /')
  tls.key: |
$(sed 's/^/    /' "$W/int.key")
  ca.crt: |
$(sed 's/^/    /' "$W/root.crt")
EOF
enc "$W/edge-ca.yaml" clusters/edge/infra/ca/edge-ca.enc.yaml

find "$W" -type f -exec shred -u {} +; rmdir "$W"
```

### 1.2 The OpenBao seal key -- `secrets/edge/openbao-seal.enc.yaml`

32 random bytes, base64 (44 characters). **Never change it** once an OpenBao
has started with it: its raft data is sealed with this key.

```bash
umask 077; T=$(mktemp)
cat > "$T" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openbao-static-seal
  namespace: openbao
type: Opaque
stringData:
  key: "$(openssl rand -base64 32)"
EOF
enc "$T" secrets/edge/openbao-seal.enc.yaml
```

### 1.3 The app values -- `secrets/edge/app-values.enc.yaml`

Every value `cluster-apps.yaml` refers to with `ref+sops://` (never applied
itself). **Four pairs must be equal** -- the two sides of one credential --
and one value is derived:

| Key | Shape (example generator) | Read by |
|---|---|---|
| `HOMERUN2_REDIS_PASSWORD` | 48 hex (`openssl rand -hex 24`) | the source of the next two |
| `HOMERUN2_REDIS_PASSWORD_B64` | **base64 of** `HOMERUN2_REDIS_PASSWORD` | homerun2, light-catcher-tabletennis |
| `ZAEHLWERK_REDIS_PASSWORD` | **= `HOMERUN2_REDIS_PASSWORD`** | zaehlwerk (panel) |
| `HOMERUN2_OMNI_PITCHER_AUTH_TOKEN` | 48 hex | homerun2 omni-pitcher |
| `ZAEHLWERK_OMNI_PITCHER_TOKEN` | **= `HOMERUN2_OMNI_PITCHER_AUTH_TOKEN`** | zaehlwerk (panel) |
| `HOMERUN2_SCOUT_AUTH_TOKEN` | 48 hex | homerun2 scout |
| `TEAMS_WEBHOOK_URL` | URL or empty (notification-catcher stays in dry run) | homerun2 |
| `SCHMETTERPAUSE_DB_USERNAME` | `schmetterpause` (fixed by the catalog) | -- |
| `SCHMETTERPAUSE_DB_PASSWORD` | 48 hex | schmetterpause, CNPG |
| `SCHMETTERPAUSE_SESSION_KEY` | 64 hex (`openssl rand -hex 32`) | schmetterpause (signs sessions; changing it signs everyone out) |
| `SCHMETTERPAUSE_SCOREBOARD_TOKEN` | 64 hex | schmetterpause `/api` **and** zaehlwerk (one credential, read twice) |
| `MINIO_ADMIN_USER` / `MINIO_ADMIN_PASSWORD` | e.g. `edge-admin` / 48 hex | MinIO, terraform/minio |
| `MINIO_CNPG_USER` / `MINIO_CNPG_PASSWORD` | `schmetterpause-cnpg` / 48 hex | terraform/minio creates this user |
| `SCHMETTERPAUSE_BACKUP_ACCESS_KEY_ID` | **= `MINIO_CNPG_USER`** | CNPG backups |
| `SCHMETTERPAUSE_BACKUP_SECRET_ACCESS_KEY` | **= `MINIO_CNPG_PASSWORD`** | CNPG backups |
| `OPENBAO_TERRAFORM_PASSWORD` | 32 alnum | OpenBao self-init user `terraform`, terraform/openbao |
| `OPENBAO_ADMIN_PASSWORD` | 32 alnum | OpenBao self-init user `admin` (break-glass, by hand only) |
| `HETZNER_DNS_TOKEN` | from the Hetzner Console (project holding only the zone, Read & Write) | cert-manager-letsencrypt-hetzner |

```bash
umask 077; T=$(mktemp)
hex() { openssl rand -hex "$1"; }
aln() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
REDIS=$(hex 24); OMNI=$(hex 24); CNPG=$(hex 24)
read -rsp 'Hetzner DNS token (input hidden): ' HETZNER; echo
cat > "$T" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: edge-app-values
  namespace: not-applied
type: Opaque
stringData:
  HOMERUN2_REDIS_PASSWORD: "$REDIS"
  HOMERUN2_REDIS_PASSWORD_B64: "$(printf %s "$REDIS" | base64 -w0)"
  ZAEHLWERK_REDIS_PASSWORD: "$REDIS"
  HOMERUN2_OMNI_PITCHER_AUTH_TOKEN: "$OMNI"
  ZAEHLWERK_OMNI_PITCHER_TOKEN: "$OMNI"
  HOMERUN2_SCOUT_AUTH_TOKEN: "$(hex 24)"
  TEAMS_WEBHOOK_URL: ""
  SCHMETTERPAUSE_DB_USERNAME: schmetterpause
  SCHMETTERPAUSE_DB_PASSWORD: "$(hex 24)"
  SCHMETTERPAUSE_SESSION_KEY: "$(hex 32)"
  SCHMETTERPAUSE_SCOREBOARD_TOKEN: "$(hex 32)"
  MINIO_ADMIN_USER: edge-admin
  MINIO_ADMIN_PASSWORD: "$(hex 24)"
  MINIO_CNPG_USER: schmetterpause-cnpg
  MINIO_CNPG_PASSWORD: "$CNPG"
  SCHMETTERPAUSE_BACKUP_ACCESS_KEY_ID: schmetterpause-cnpg
  SCHMETTERPAUSE_BACKUP_SECRET_ACCESS_KEY: "$CNPG"
  OPENBAO_TERRAFORM_PASSWORD: "$(aln 32)"
  OPENBAO_ADMIN_PASSWORD: "$(aln 32)"
  HETZNER_DNS_TOKEN: "$HETZNER"
EOF
unset REDIS OMNI CNPG HETZNER
enc "$T" secrets/edge/app-values.enc.yaml
```

Later additions to an existing file -- one key, without decrypting the rest:

```bash
sops set secrets/edge/app-values.enc.yaml '["stringData"]["NEW_KEY"]' "\"$(openssl rand -hex 32)\""
```

### Check

```bash
for f in secrets/edge/*.enc.yaml clusters/edge/infra/ca/edge-ca.enc.yaml; do
  sops -d "$f" >/dev/null && echo "ok $f"; done
sops -d secrets/edge/app-values.enc.yaml | yq '.stringData | keys | length'     # 20
```

## 2. Cluster files

Per cluster, in `clusters/<cluster>/` -- the example is `edge-test2` (labul).
Set once per shell:

```bash
CLUSTER=edge-test2                 # folder name: clusters/$CLUSTER
mkdir -p clusters/$CLUSTER/{infra/ca,k3s}
```

### 2.1 `clusters/$CLUSTER/cluster-vars.yaml`

What differs between environments -- the only place with addresses and names.
Every layer substitutes `${EDGE_*}` from it.

```bash
cat > clusters/$CLUSTER/cluster-vars.yaml <<'EOF'
---
# What differs between environments (lab VM / box). Only plain strings, no
# secrets. Every layer substitutes ${EDGE_*} from this ConfigMap.
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-vars
  namespace: flux-system
data:
  EDGE_CLUSTER_NAME: edge-tt-test2
  # internal names: *.EDGE_DOMAIN -> EDGE_LB_IP (Clusterbook / the router)
  EDGE_DOMAIN: edge-tt-test2.sthings-vsphere.labul.sva.de
  EDGE_LB_IP: 10.31.102.7
  EDGE_GATEWAY_NAME: edge-gateway
  # public players' names: *.EDGE_PLAY_DOMAIN -> EDGE_PLAY_LB_IP (Hetzner DNS)
  EDGE_PLAY_DOMAIN: test2.sthings-edge.com
  EDGE_PLAY_LB_IP: 10.31.102.8
  # lab only: the ESP mock ("0" while real boards play)
  EDGE_ESP_MOCK_REPLICAS: "1"
EOF
```

### 2.2 `clusters/$CLUSTER/cluster-apps.yaml`

The input of `render-cluster-apps`: what the cluster runs. Copy of the edge's,
with the cluster's path; values come from `cluster-vars` (`${EDGE_*}`) or, for
secrets, `ref+sops://` into section 1. Drop the `edge-lab` layer for the box.

```bash
cat > clusters/$CLUSTER/cluster-apps.yaml <<'EOF'
---
# Input of blueprints/flux render-cluster-apps -- NOT a Kubernetes object
# (.sourceignore). See clusters/edge/FROM-SCRATCH.md and the README runbook.
kind: ClusterApps
metadata:
  name: __CLUSTER__
spec:
  source:
    kind: OCIRepository
    name: flux-repo
    url: oci://ghcr.io/stuttgart-things/flux/repo
    tag: v1.125.0
    interval: 1h
  path: ./clusters/__CLUSTER__
  secrets:
    mode: inline
  wiring:
    generate: true
    extraResources: [cluster-vars.yaml]
  layers:
    edge-infra:
      dir: infra
      extraResources: [ca.yaml]
      labels:
        app.kubernetes.io/managed-by: flux
        kustomization.stuttgart-things.com/type: infrastructure
      timeout: 15m
      substituteFrom:
        - kind: ConfigMap
          name: cluster-vars
          optional: false
    edge-apps:
      dir: apps
      labels:
        app.kubernetes.io/managed-by: flux
        kustomization.stuttgart-things.com/type: apps
      dependsOn: [edge-infra]
      wait: false
      decryptionSecret: sops-age # pragma: allowlist secret
      substituteFrom:
        - kind: ConfigMap
          name: cluster-vars
          optional: false
    # LAB ONLY -- remove for the box (and the lab/ folder)
    edge-lab:
      dir: lab
      labels:
        app.kubernetes.io/managed-by: flux
        kustomization.stuttgart-things.com/type: infrastructure
      dependsOn: [edge-infra]
      timeout: 10m
      substituteFrom:
        - kind: ConfigMap
          name: cluster-vars
          optional: false
  bundles:
    infra-platform:
      layer: edge-infra
      timeout: 10m
    apps-platform:
      layer: edge-apps
  vars:
    INFRA_DOMAIN: ${EDGE_DOMAIN}
    INFRA_GATEWAY_NAME: ${EDGE_GATEWAY_NAME}
    INFRA_GATEWAY_NAMESPACE: default
    INFRA_TLS_SECRET: wildcard-tls # pragma: allowlist secret
  apps:
    cilium-lb:
      vars:
        CILIUM_LB_IP_START: ${EDGE_LB_IP}
        CILIUM_LB_IP_STOP: ${EDGE_LB_IP}
    cilium-gateway: {}
    cert-manager-install: {}
    cert-manager-selfsigned:
      vars:
        CERT_MANAGER_SELFSIGNED_ISSUER: edge-ca
    cert-manager-ca-from-secret:
      vars:
        CERT_MANAGER_CA_FROM_SECRET_ISSUER: edge-ca # pragma: allowlist secret
        CERT_MANAGER_CA_FROM_SECRET_NAME: edge-ca # pragma: allowlist secret
    trust-manager:
      vars:
        TRUST_BUNDLE_VAULT_CA_SECRET: edge-ca # pragma: allowlist secret
    cert-manager-letsencrypt-hetzner:
      secrets:
        cert-manager-letsencrypt-hetzner-secrets:
          HETZNER_DNS_TOKEN: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/HETZNER_DNS_TOKEN # pragma: allowlist secret
    cilium-gateway-extra:
      vars:
        CILIUM_GATEWAY_EXTRA_NAME: edge-play-gateway
        CILIUM_GATEWAY_EXTRA_NAMESPACE: default
        CILIUM_GATEWAY_EXTRA_POOL_NAME: edge-play-pool
        CILIUM_GATEWAY_EXTRA_IP: ${EDGE_PLAY_LB_IP}
        CILIUM_GATEWAY_EXTRA_DOMAIN: ${EDGE_PLAY_DOMAIN}
        CILIUM_GATEWAY_EXTRA_ISSUER: letsencrypt-hetzner
        CILIUM_GATEWAY_EXTRA_ISSUER_KIND: ClusterIssuer
        CILIUM_GATEWAY_EXTRA_TLS_SECRET: play-wildcard-tls # pragma: allowlist secret
        CILIUM_GATEWAY_EXTRA_ISSUER_KUSTOMIZATION: cert-manager-letsencrypt-hetzner
    cnpg-operator: {}
    cnpg-barman-cloud: {}
    reloader: {}
    minio:
      vars:
        MINIO_STORAGE_CLASS: local-path
        MINIO_STORAGE_SIZE: 5Gi
        MINIO_VERSION: 16.0.10
      secrets:
        minio-secrets:
          MINIO_ADMIN_USER: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/MINIO_ADMIN_USER
          MINIO_ADMIN_PASSWORD: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/MINIO_ADMIN_PASSWORD # pragma: allowlist secret
    homerun2-sops:
      vars:
        HOMERUN2_NAMESPACE: homerun2
        HOMERUN2_REDIS_STORAGE_CLASS: local-path
        HOMERUN2_REDIS_STORAGE_SIZE: 1Gi
        HOMERUN2_LED_CATCHER_UI_STREAM_PRESETS: messages,tabletennis
      secrets:
        homerun2-sops-secrets:
          HOMERUN2_REDIS_PASSWORD_B64: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/HOMERUN2_REDIS_PASSWORD_B64 # pragma: allowlist secret
          TEAMS_WEBHOOK_URL: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/TEAMS_WEBHOOK_URL
          HOMERUN2_OMNI_PITCHER_AUTH_TOKEN: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/HOMERUN2_OMNI_PITCHER_AUTH_TOKEN # pragma: allowlist secret
          HOMERUN2_SCOUT_AUTH_TOKEN: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/HOMERUN2_SCOUT_AUTH_TOKEN # pragma: allowlist secret
    homerun2-light-catcher-tabletennis-sops:
      secrets:
        homerun2-light-catcher-tabletennis-sops-secrets:
          HOMERUN2_REDIS_PASSWORD_B64: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/HOMERUN2_REDIS_PASSWORD_B64 # pragma: allowlist secret
    tabletennis-sops-backup:
      vars:
        TABLETENNIS_ZAEHLWERK_PANEL: homerun2
        TABLETENNIS_SCHMETTERPAUSE_DB_STORAGE_SIZE: 1Gi
        TABLETENNIS_SCHMETTERPAUSE_BACKUP_BUCKET: schmetterpause-cnpg
        TABLETENNIS_SCHMETTERPAUSE_BACKUP_S3_ENDPOINT: http://minio-deployment.minio.svc.cluster.local:9000
        TABLETENNIS_SCHMETTERPAUSE_BACKUP_SERVER_NAME: schmetterpause-db-__CLUSTER__
        TABLETENNIS_SCHMETTERPAUSE_BACKUP_RETENTION: 7d
        TABLETENNIS_SCOREBOARD_HANDOVER: sops
        TABLETENNIS_SCHMETTERPAUSE_ADMIN: 'on'
        TABLETENNIS_SCHMETTERPAUSE_BOOTSTRAP_ADMIN: timoboll
      secrets:
        tabletennis-sops-secrets:
          SCHMETTERPAUSE_DB_PASSWORD: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/SCHMETTERPAUSE_DB_PASSWORD # pragma: allowlist secret
          SCHMETTERPAUSE_SESSION_KEY: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/SCHMETTERPAUSE_SESSION_KEY # pragma: allowlist secret
          ZAEHLWERK_OMNI_PITCHER_TOKEN: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/ZAEHLWERK_OMNI_PITCHER_TOKEN # pragma: allowlist secret
          ZAEHLWERK_REDIS_PASSWORD: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/ZAEHLWERK_REDIS_PASSWORD # pragma: allowlist secret
          SCHMETTERPAUSE_BACKUP_ACCESS_KEY_ID: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/SCHMETTERPAUSE_BACKUP_ACCESS_KEY_ID # pragma: allowlist secret
          SCHMETTERPAUSE_BACKUP_SECRET_ACCESS_KEY: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/SCHMETTERPAUSE_BACKUP_SECRET_ACCESS_KEY # pragma: allowlist secret
          SCHMETTERPAUSE_SCOREBOARD_TOKEN: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/SCHMETTERPAUSE_SCOREBOARD_TOKEN # pragma: allowlist secret
    openbao-sops:
      vars:
        OPENBAO_TOPOLOGY: single-node
        OPENBAO_STORAGE_CLASS: local-path
        OPENBAO_STORAGE_SIZE: 2Gi
        OPENBAO_SEAL_KEY_ID: edge-20261004
        OPENBAO_INIT: self-init-userpass
      secrets:
        openbao-sops-secrets:
          OPENBAO_SEAL_STATIC_KEY: ref+sops://secrets/edge/openbao-seal.enc.yaml#/stringData/key # pragma: allowlist secret
          OPENBAO_TERRAFORM_PASSWORD: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/OPENBAO_TERRAFORM_PASSWORD # pragma: allowlist secret
          OPENBAO_ADMIN_PASSWORD: ref+sops://secrets/edge/app-values.enc.yaml#/stringData/OPENBAO_ADMIN_PASSWORD # pragma: allowlist secret
EOF
sed -i "s|__CLUSTER__|$CLUSTER|g" clusters/$CLUSTER/cluster-apps.yaml
```

Pick the newest `spec.source.tag` (the flux releases). The backup server name
must be unique per cluster when several archive into one bucket.

### 2.3 `clusters/$CLUSTER/infra/ca.yaml` + `infra/ca/kustomization.yaml`

The Flux Kustomization that applies the intermediate (section 1.1). Copy
`edge-ca.enc.yaml` from another edge cluster, or create it there.

```bash
cat > clusters/$CLUSTER/infra/ca.yaml <<'EOF'
---
# The persistent edge CA's intermediate (Secret cert-manager/edge-ca, SOPS),
# read by the ClusterIssuer edge-ca (cert-manager-ca-from-secret).
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: edge-ca
  namespace: flux-system
  labels:
    app.kubernetes.io/managed-by: flux
    kustomization.stuttgart-things.com/type: infrastructure
spec:
  dependsOn:
    - name: cert-manager-install
  interval: 1h
  retryInterval: 30s
  timeout: 5m
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./clusters/__CLUSTER__/infra/ca
  decryption:
    provider: sops
    secretRef:
      name: sops-age # pragma: allowlist secret
EOF
sed -i "s|__CLUSTER__|$CLUSTER|g" clusters/$CLUSTER/infra/ca.yaml
cat > clusters/$CLUSTER/infra/ca/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - edge-ca.enc.yaml
EOF
cp clusters/edge/infra/ca/edge-ca.enc.yaml clusters/$CLUSTER/infra/ca/
cp clusters/edge/edge-root-ca.crt clusters/$CLUSTER/
```

### 2.4 `clusters/$CLUSTER/.sourceignore`

```bash
cat > clusters/$CLUSTER/.sourceignore <<'EOF'
# Flux never reads these: run by hand / by dagger, not by a controller.
k3s/
terraform/
# the input of render-cluster-apps, no Kubernetes object
cluster-apps.yaml
EOF
```

### 2.5 `clusters/$CLUSTER/k3s/` -- inventory, vars, collections

```bash
cat > clusters/$CLUSTER/k3s/inventory.ini <<'EOF'
# The node. Cluster layout, not [all]: sthings.rke's role branches on these groups.
[initial_master_node]
10.31.102.144

[additional_master_nodes]

[all:vars]
ansible_user=sthings
EOF
sed -e "s/^cluster_name: edge$/cluster_name: $CLUSTER/" \
    -e "s|^fetched_kubeconfig_path: .*|fetched_kubeconfig_path: /tmp/kubeconfig-$CLUSTER.yaml|" \
    clusters/edge/k3s/k3s-vars.yaml > clusters/$CLUSTER/k3s/k3s-vars.yaml
cp clusters/edge/k3s/requirements.yaml clusters/$CLUSTER/k3s/
```

`k3s-vars.yaml` in full (what the `sed` produces):

```yaml
---
manage_filesystem: false
install_k3s: true
k3s_state: present
k3s_k8s_version: 1.35.9
k3s_release_kind: k3s1
k3s_cluster_init: false          # sqlite/kine, no embedded etcd
cluster_setup: singlenode
cluster_name: edge-test2
install_cilium: true
cilium_version: 0.20.1           # cilium-cli
cilium_chart_version: "1.20.2"
cilium_gateway_api_crds_version: v1.6.1
prepare_rancher_ha_nodes: true
install_helm_diff: false
fetched_kubeconfig_path: /tmp/kubeconfig-edge-test2.yaml
```

### 2.6 `clusters/$CLUSTER/lab/` -- lab VMs only

The ESP mock and the players' route, copied from the edge's `lab/` (the
LabDA-only parts -- Vault issuer, CoreDNS forward to the LabDA resolver -- stay
out on other labs):

```bash
mkdir -p clusters/$CLUSTER/lab
cp -r clusters/edge/lab/{esp-mock,esp-mock.yaml,play-routes,play-routes.yaml} clusters/$CLUSTER/lab/
cp clusters/edge/edge-root-ca.crt clusters/$CLUSTER/lab/esp-mock/
cat > clusters/$CLUSTER/lab/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - play-routes.yaml
  # an emulated ESP32 (piezo mock + ACME device certificate from OpenBao)
  - esp-mock.yaml
EOF
sed -i "s|./clusters/edge/lab/|./clusters/$CLUSTER/lab/|" clusters/$CLUSTER/lab/*.yaml
```

### Then

Render (README step 5: `render-cluster-apps` with
`--cluster-apps clusters/$CLUSTER/cluster-apps.yaml`; the **first** render
without `--existing-secrets`), merge, bootstrap Flux with
`--destination-path clusters/$CLUSTER` (step 6). Generated:
`kustomization.yaml`, `apps.yaml`, `infra/kustomization.yaml`,
`infra/infra-platform.yaml`, `apps/*`, `cluster-secrets/`; committed by the
bootstrap: `config.yaml`, `secrets.yaml`.

## 3. Terraform env files

The Terraform roots are shared (`clusters/edge/terraform/{openbao,minio}`);
each environment has its own address file, passed with `--extra-files`
(README step 8). No defaults: without the file a run fails.

```bash
ENV=lab-test2
cat > clusters/edge/terraform/openbao/env/$ENV.auto.tfvars.json <<'EOF'
{
  "openbao_addr": "https://openbao.edge-tt-test2.sthings-vsphere.labul.sva.de",
  "acme_allowed_domains": ["edge-tt-test2.sthings-vsphere.labul.sva.de"],
  "acme_dns_resolver": ""
}
EOF
cat > clusters/edge/terraform/minio/env/$ENV.auto.tfvars.json <<'EOF'
{
  "minio_server": "minio.edge-tt-test2.sthings-vsphere.labul.sva.de:443"
}
EOF
```

`acme_dns_resolver`: empty = the cluster DNS (lab); the router on the box
(`"192.168.8.1:53"`).
