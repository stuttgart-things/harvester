# OpenBao Kubernetes auth for the clusterbook-managed clusters

`crossplane-mgmt`, `k3s-xp` and `apps1`. One shared document because they are
identical apart from a name; each `<cluster>/openbao/` directory holds only what
differs.

`apps1` is the first built this way from the start — it never talks to the Vault
on `infra` at all. `k3s-xp` and `crossplane-mgmt` were migrated on 2026-09-08.

`ferdinand` was a fourth. It was deleted on 2026-09-07 and replaced by `apps1`,
and its `ferdinand/openbao/` directory is gone with it — but it is where the CA
finding below was made, so it still appears in this document as evidence.

Context and the wider migration: [harvester#152][152]. Read
[`platform/openbao/README.md`](platform/openbao/README.md) first — it is the
run that creates the PKI everything here signs against.

## Why these are not like `platform` or `xplane`

Same Terraform half, different issuer half.

|  | `platform`, `xplane` | these |
|---|---|---|
| Auth mount (Terraform) | `<cluster>/openbao/` | `<cluster>/openbao/` — same |
| ClusterIssuer | a Flux `Kustomization` in `<cluster>/infra.yaml` | the **`cert-manager-vault-pki-clusterbook` ApplicationSet** |
| Configured by | `VAULT_ISSUER_*` substitutions in this repo | `clusterbook.stuttgart-things.com/vault-*` annotations on the **RancherCluster XR**, in `stuttgart-things/crossplane-configurations` |

So these clusters get **no** `cert-manager-openbao-issuer` Kustomization and no
`openbao-pki-ca.yaml` here. The chain that configures them is:

```
RancherCluster XR (crossplane-configurations)
  → ClusterbookCluster (platform)
    → Argo CD cluster Secret annotations
      → ApplicationSet cert-manager-vault-pki-clusterbook
        → chart infra/cert-manager/vault-pki on the target cluster
```

Which is why the mount name below is not free: it has to match the
`vault-k8s-auth-mount` annotation on the XR exactly.

## Order, and what fails silently

1. **`platform/openbao` applied.** It creates the PKI, the `sthings-lab` signing
   role and the `pki-issue` policy. Everything here depends on it and **will not
   tell you if it is missing** — a role bound to a policy that does not exist
   logs in successfully and is granted nothing, so it surfaces as a denied
   signing request much later, not as an error during apply.
2. **This directory**, per cluster — the auth mount.
3. **[argocd#376][376] merged and the ApplicationSet's `targetRevision` bumped
   past it.** It ships the `cert-manager-tokenrequest` Role. Without that Role
   cert-manager cannot mint the login token, and the failure is invisible where
   you would look: the ClusterIssuer reports `Ready=True` — it verifies the
   Vault *login*, never the ability to sign — while no Certificate is ever
   issued. The only signal is the cert-manager log.
4. **The CA.** See below; it is the one step that is not a name change.
5. **The XR annotations** — the actual switch, in `crossplane-configurations`.

## The CA is the real work

The OpenBao PKI is a **new root**. The old `sthings.lab` root in the infra Vault
was created as `internal`, so its key cannot be exported and could not be
carried over; the two share a common name and nothing else. Measured on
`ferdinand` on 2026-09-07, the day before that cluster was deleted:

```
vault-pki-ca on ferdinand   notBefore Mar  4 2026   sha256 23:3A:6A:BB:…
OpenBao serves              notBefore Sep  2 2026   sha256 4E:3F:AD:1D:…
```

`crossplane-mgmt` still carried that same March root a day later, for a reason
worth knowing: step (5b) below pushes the CA onto **downstream** clusters, and
`crossplane-mgmt` is not downstream of itself. Its `vault-pki-ca` is therefore
declared in git, in this repo under
`clusters/crossplane-mgmt/platform/vault-pki/`.

The ApplicationSet passes `caBundleSecretRef: {name: vault-pki-ca, key: ca.crt}`,
so **that** Secret on each target cluster has to carry the new root before the
annotations are flipped. Point the URL at OpenBao while it still holds the March
CA and the issuer fails exactly as it does against the expired infra Vault
today, only with a different hostname in the message.

On these clusters `vault-pki-ca` is written by step (5b) of the `rancher-cluster`
Composition, from the source Secret named by `vaultPkiSourceCaName` in the
EnvironmentConfig on `crossplane-mgmt` — that is where the new root has to land.
The CA *certificate* is not secret; nothing here needs SOPS.

## Applying

Per cluster, from its own `openbao/` directory:

```bash
export VAULT_ADDR=https://openbao.platform.sthings.lab
# The root token — the only credential that may write auth mounts here.
# Recorded in platform/openbao/README.md; stored in that same directory.
export VAULT_TOKEN=$(sops --decrypt ../../../secrets/openbao-platform-init.enc.yaml \
  | python3 -c 'import yaml,sys; print(yaml.safe_load(sys.stdin)["root_token"])')

KUBECONFIG_PATH=<this cluster's kubeconfig> \
  ../../platform/openbao/preflight.sh && terraform init && terraform apply
```

The preflight is shared rather than copied — it reads the `.tf` in the current
directory and compares it against the live cluster.

**These clusters have no `~/.kube/<name>` file.** They are reachable through the
direct-endpoint kubeconfig Argo CD holds, which is also what the Terraform
`kubernetes` backend and `kubeconfig_path` want. Deliberately the direct
endpoint and not Rancher's proxy: on 2026-09-07 every downstream agent was
disconnected for days after a CA rotation, and an auth mount that can only be
configured while Rancher is healthy is a dependency worth not having.

```bash
CLUSTER=k3s-xp   # or crossplane-mgmt
kubectl --kubeconfig ~/.kube/platform.sthings.lab -n argocd \
  get secret cluster-$CLUSTER -o json \
| python3 -c '
import sys, json, base64, os
d = json.load(sys.stdin)["data"]
cfg = json.loads(base64.b64decode(d["config"]))
name = base64.b64decode(d["name"]).decode()
print(json.dumps({
    # The context MUST be called "default". vault-base-setup passes var.context
    # (default: "default") to the kubernetes provider as config_context, so a
    # context named after the cluster fails the apply with
    #   Error: Provider configuration: cannot load Kubernetes client config
    #   context "default" does not exist
    # ~/.kube/platform.sthings.lab is named that way too.
    "apiVersion": "v1", "kind": "Config", "current-context": "default",
    "clusters": [{"name": name, "cluster": {
        "server": base64.b64decode(d["server"]).decode(),
        "certificate-authority-data": cfg["tlsClientConfig"]["caData"]}}],
    "contexts": [{"name": "default", "context": {"cluster": name, "user": name}}],
    "users": [{"name": name, "user": {"token": cfg["bearerToken"]}}]}))
' > ~/.kube/$CLUSTER
chmod 600 ~/.kube/$CLUSTER
```

`k8s_auth_reviewer_create` is left at its default. Checked on the three that existed on
2026-09-07: `kube-system/vault-auth-reviewer` does not exist on any of them, so
the module creates it. `blueprints CreateVaultKubernetesAuth` would own that
identity on a pipeline-built cluster — these were not built that way. The
preflight re-checks it rather than trusting this paragraph.

## Verifying

**First: nudge the issuer.** It was created before the auth mount existed, and a
ClusterIssuer that failed once keeps that failure on its status rather than
retrying on any useful cadence. On apps1, 2026-09-07, it still read

```
Failed to initialize Vault client: ... serviceaccounts "certmanager" not found
```

three hours after Terraform had created that ServiceAccount. Certificates queue
behind it with `Referenced issuer does not have a Ready status condition`, which
points at the issuer and explains nothing. Any write triggers a reconcile:

```bash
export KUBECONFIG=~/.kube/$CLUSTER
kubectl annotate clusterissuer vault-pki reconcile=$(date +%s) --overwrite
kubectl get clusterissuer vault-pki      # Ready=True within seconds
```

Compare the condition's `lastTransitionTime` against the `creationTimestamp` of
whatever it complains about before taking the message at face value.

Then: `Ready=True` proves the Vault **login** works and nothing else. Only an
issued Certificate is evidence:

```bash
export KUBECONFIG=~/.kube/$CLUSTER
kubectl apply -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: openbao-probe, namespace: default}
spec:
  secretName: openbao-probe-tls
  commonName: probe.example.sthings.lab
  dnsNames: [probe.example.sthings.lab]
  issuerRef: {name: vault-pki, kind: ClusterIssuer}
  duration: 2160h
  renewBefore: 360h
YAML
kubectl get certificate openbao-probe -w

# the chain must come from the NEW root — 4E:3F:AD:…, notBefore Sep 2 2026
kubectl get secret openbao-probe-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -dates
```

Note the issuer is still named `vault-pki` on these clusters: the ApplicationSet
takes the name from the `wildcard-issuer-name` annotation, and keeping it means
existing Certificates move with the annotation flip instead of needing an
`issuerRef` edit each. The name says Vault; the endpoint it talks to is OpenBao.

[152]: https://github.com/stuttgart-things/harvester/issues/152
[376]: https://github.com/stuttgart-things/argocd/pull/376
