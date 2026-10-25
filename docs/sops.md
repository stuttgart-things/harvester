# SOPS + age -- secrets in git

How this repo keeps secrets in git: what SOPS and age are, what you need, the
age key, the config, and encrypting/decrypting -- with the plain CLI **or** our
Dagger modules. Used everywhere secrets live here: `secrets/` (kubeconfigs,
the edge's persistent secrets), the cluster folders (`*.enc.yaml` that Flux
applies), and the files `render-cluster-apps` generates.

## What it is

- **[SOPS](https://github.com/getsops/sops)** encrypts the **values** of a
  YAML/JSON/ENV file and leaves the **keys** readable. A diff shows *which*
  field changed without showing the secret; the file stays valid YAML. The
  metadata (who may decrypt, a MAC over the content) sits in the file under
  `sops:`.
- **[age](https://github.com/FiloSottile/age)** is the encryption SOPS uses
  here: a key pair -- the **public key** (`age1…`) encrypts, the **private
  key** (`AGE-SECRET-KEY-1…`) decrypts. No GPG, no key server.
- **Flux** decrypts in the cluster: the Kustomization's `decryption` block
  (`provider: sops`, `secretRef: sops-age`) points at a Secret holding the
  private key, and Flux decrypts every `*.enc.yaml` it applies.

## What you need

Pick one -- the result is the same file.

| | Option 1: sops + age CLI | Option 2: Dagger modules |
|---|---|---|
| Install | `sops` (3.12+) and `age` (1.2+) | the Dagger CLI (0.21+) and Docker -- nothing else |
| Good for | interactive work: editing in place (`sops file.enc.yaml` opens `$EDITOR`) | nothing to install but Dagger; pinned sops 3.13.3 / age 1.3.2 in the container; pipelines |
| Both | encrypt (whole file or `data`/`stringData` only), decrypt (whole file or one value), change one value, change the recipients, derive the public key | the same |
| Limit | -- | no in-place editing; every call starts a container (slower in loops) |

**Install option 1** (Linux, amd64):

```bash
SOPS_VERSION=3.12.1; AGE_VERSION=1.2.1
curl -fsSLo /tmp/sops "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64"
sudo install -m 755 /tmp/sops /usr/local/bin/sops
curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
sudo install -m 755 /tmp/age/age /tmp/age/age-keygen /usr/local/bin/
sops --version; age --version
```

Or all of it as Ansible code -- sops, age and the Dagger CLI, plus Docker:
[Workstation setup](workstation.md).

**Option 2:** Docker and the Dagger CLI ([Workstation setup](workstation.md)); the modules:
`github.com/stuttgart-things/dagger/sops` v0.137.0+ (`encrypt` with optional
`--encrypted-regex`, `decrypt` with optional `--extract`, `set`,
`update-keys`, `age-public-key`, `generate-age-key`, `generate-sops-config`) and `github.com/stuttgart-things/blueprints/secrets`
(encrypt-file, decrypt, cluster keys, rendering secrets).

## The age key

**One master key for the repo**: every SOPS file here is encrypted for it, so
whoever holds it can read everything. Keep the private key **outside** the
repo -- in a file with mode 600 and in the team's password manager. Losing it
means losing every secret.

```bash
# use the team's key
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
# (paste it from the password manager into ~/.config/sops/age/keys.txt, mode 600)
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt          # sops reads it from here (also the default path)
export SOPS_AGE_KEY=$(cat ~/.config/sops/age/keys.txt)         # the Dagger modules and Flux bootstraps take it like this
export AGE_PUB=$(age-keygen -y ~/.config/sops/age/keys.txt)    # the public key: age1...
#   Dagger: export AGE_PUB=$(dagger call -s -m github.com/stuttgart-things/dagger/sops@v0.137.1 age-public-key --age-key env:SOPS_AGE_KEY)

# none yet -- a new key pair
age-keygen -o ~/.config/sops/age/keys.txt && chmod 600 ~/.config/sops/age/keys.txt
#   Dagger: dagger call -m github.com/stuttgart-things/dagger/sops@v0.137.1 generate-age-key
```

**Cluster keys.** A cluster can decrypt with its own key instead of the master
key (the edge box does): `render-cluster-apps` generates it
(`cluster-secrets/sops-age.enc.yaml`, encrypted for the master key -- the
*escrow*) and encrypts the cluster's secrets for **both** keys
(`--escrow-recipients`). Flux on that cluster gets only the cluster key; the
team still reads everything with the master key. Its private key:
`dagger call -m github.com/stuttgart-things/blueprints/secrets@v3.11.0 cluster-age-key --existing <cluster-secrets dir> --master-age-key env:SOPS_AGE_KEY plaintext`.

**In the cluster** the private key is the Secret `flux-system/sops-age` (key
`age.agekey`), created by the Flux bootstrap (`--sops-age-key`).

## The config: `.sops.yaml`

Optional. Without it, pass the recipient on the command line (`--age
"$AGE_PUB"`) -- that is how the docs here do it. With it, `sops --encrypt`
picks recipients and the encrypted fields by path:

```bash
cat > .sops.yaml <<EOF
creation_rules:
  # Kubernetes Secrets: only data/stringData -- apiVersion, kind, metadata stay readable
  - path_regex: \.ya?ml$
    encrypted_regex: ^(data|stringData)$
    age: $AGE_PUB
EOF
#   Dagger: dagger call -m github.com/stuttgart-things/dagger/sops@v0.137.1 generate-sops-config \
#     --age-public-key "$AGE_PUB" --path-regex '\.ya?ml$' \
#     --encrypted-regex '^(data|stringData)$' export --path .sops.yaml
```

`path_regex` is matched against the file **being encrypted**, and that is the
plaintext file (`secret.yaml`), not the target. A rule for `.*\.enc\.yaml$`
therefore matches only in-place runs (`sops secret.enc.yaml`, `sops -e -i`). The
Dagger module matches against its own name for the file, `encrypted.yaml`.
`\.ya?ml$` fits both.

`render-cluster-apps` writes one into each `cluster-secrets/` (the cluster key
and the escrow recipient). The repo has none at its root: every command passes
`--age` and, for Secrets, `--encrypted-regex`.

**Which fields?** A Kubernetes Secret that **Flux applies** must keep
`apiVersion`, `kind` and `metadata` readable -- encrypt only
`data|stringData`. Files nobody applies (kubeconfigs, `secrets/edge/*` value
files) may be encrypted whole.

## Encrypt and decrypt

Conventions: encrypted files end in **`.enc.yaml`** (the pre-commit hooks skip
them); plaintext only under `umask 077` in a temp dir and `shred -u` it
afterwards; never `echo` a secret into a terminal or a log.

### Option 1: sops CLI

```bash
# a Kubernetes Secret (Flux applies it): only data/stringData
sops --encrypt --age "$AGE_PUB" --encrypted-regex '^(data|stringData)$' \
  secret.yaml > secret.enc.yaml && shred -u secret.yaml

# a whole file (kubeconfig, value file)
sops --encrypt --age "$AGE_PUB" --input-type yaml --output-type yaml \
  ~/.kube/edge-tt-test2 > secrets/edge/kubeconfig-edge-tt-test2.enc.yaml

# decrypt -- to stdout, to a file, one value
sops -d secret.enc.yaml
(umask 077; sops -d secrets/edge/kubeconfig-edge-tt-test2.enc.yaml > ~/.kube/edge-tt-test2)
sops -d --extract '["stringData"]["HETZNER_DNS_TOKEN"]' secrets/edge/app-values.enc.yaml

# change things without a plaintext file
sops secret.enc.yaml                                                     # opens $EDITOR, re-encrypts on save
sops set secrets/edge/app-values.enc.yaml '["stringData"]["NEW_KEY"]' '"value"'
sops updatekeys secret.enc.yaml                                          # after changing the recipients in .sops.yaml
```

### Option 2: Dagger

The same operations, with `dagger/sops` v0.137.0+. Each function returns a
file (`export --path` writes it, `contents` prints it) or, for
`age-public-key`, a string.

```bash
M=github.com/stuttgart-things/dagger/sops@v0.137.1

# a Kubernetes Secret (Flux applies it): only data/stringData
env -u SSH_AUTH_SOCK dagger call -m $M encrypt \
  --age-key env:AGE_PUB --encrypted-regex '^(data|stringData)$' \
  --plaintext-file secret.yaml export --path secret.enc.yaml && shred -u secret.yaml

# a whole file (kubeconfig, value file)
env -u SSH_AUTH_SOCK dagger call -m $M encrypt \
  --age-key env:AGE_PUB --plaintext-file ~/.kube/edge-tt-test2 \
  export --path secrets/edge/kubeconfig-edge-tt-test2.enc.yaml

# or let a .sops.yaml decide: recipients AND encrypted_regex from its rule
# (no --age-key -- it would replace the rule's recipients)
env -u SSH_AUTH_SOCK dagger call -m $M encrypt \
  --sops-config .sops.yaml \
  --plaintext-file secret.yaml export --path secret.enc.yaml

# decrypt -- to stdout, to a file, one value
env -u SSH_AUTH_SOCK dagger call -s -m $M decrypt --age-key env:SOPS_AGE_KEY \
  --encrypted-file secret.enc.yaml contents
(umask 077; env -u SSH_AUTH_SOCK dagger call -m $M decrypt --age-key env:SOPS_AGE_KEY \
  --encrypted-file secrets/edge/kubeconfig-edge-tt-test2.enc.yaml export --path ~/.kube/edge-tt-test2)
env -u SSH_AUTH_SOCK dagger call -s -m $M decrypt --age-key env:SOPS_AGE_KEY \
  --encrypted-file secrets/edge/app-values.enc.yaml --extract '["stringData"]["HETZNER_DNS_TOKEN"]' contents

# change one value -- the new value as a Dagger secret (env: or file:), never on the command line
NEW_VALUE=$(openssl rand -hex 32) env -u SSH_AUTH_SOCK dagger call -m $M set \
  --age-key env:SOPS_AGE_KEY --encrypted-file secrets/edge/app-values.enc.yaml \
  --path '["stringData"]["NEW_KEY"]' --value env:NEW_VALUE \
  export --path secrets/edge/app-values.enc.yaml

# change the recipients (after editing .sops.yaml)
env -u SSH_AUTH_SOCK dagger call -m $M update-keys \
  --age-key env:SOPS_AGE_KEY --encrypted-file secret.enc.yaml --sops-config .sops.yaml \
  export --path secret.enc.yaml
```

`blueprints/secrets` (v3.11.0+) adds helpers on top: it builds a Kubernetes
Secret from `key=value` pairs that Flux can apply, and its `encrypt-file`
returns the text instead of a file:

```bash
B=github.com/stuttgart-things/blueprints/secrets@v3.11.0
env -u SSH_AUTH_SOCK dagger call -m $B create-kubernetes-secret --name my-secret \
  --namespace flux-system --key-values "USER=admin" --age-public-key env:AGE_PUB \
  export --path my-secret.enc.yaml
env -u SSH_AUTH_SOCK dagger call -m $B encrypt-file --age-public-key env:AGE_PUB \
  --plaintext-file values.yaml > values.enc.yaml
```

`--key-values` passes the values on the command line, so use it only for values
that are not secret. Put secret values in a file and use `encrypt
--encrypted-regex`.

`env -u SSH_AUTH_SOCK`: a stale agent socket makes Dagger fail with `failed
to list SSH agent identities`.

## Kubeconfigs in the repo

Each cluster's admin kubeconfig is kept encrypted in `secrets/` -- the team
gets cluster access from git, and steps that need it (Terraform, Vault auth)
read it from there. The k3s kubeconfig holds a **cluster-admin** client
certificate: encrypted in git is fine, plaintext never. k3s renews client
certificates after about a year -- re-encrypt then.

| Cluster | File |
|---|---|
| `edge-tt-test1` | `secrets/edge/kubeconfig-edge-tt-test1.enc.yaml` |
| `edge-tt-test2` | `secrets/edge/kubeconfig-edge-tt-test2.enc.yaml` |
| older clusters | `secrets/<cluster>.yaml` ([secrets/README.md](https://github.com/stuttgart-things/harvester/blob/main/secrets/README.md)) |

```bash
# store (after the k3s install, see edge/k3s.md)
sops --encrypt --age "$AGE_PUB" --input-type yaml --output-type yaml \
  ~/.kube/<cluster> > secrets/edge/kubeconfig-<cluster>.enc.yaml
# check without writing plaintext to disk
sops -d secrets/edge/kubeconfig-<cluster>.enc.yaml | KUBECONFIG=/dev/stdin kubectl get nodes
# restore
(umask 077; sops -d secrets/edge/kubeconfig-<cluster>.enc.yaml > ~/.kube/<cluster>)
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `failed to get the data key required to decrypt the SOPS file` | your private key is not a recipient of the file (wrong key, or not in `SOPS_AGE_KEY`/`SOPS_AGE_KEY_FILE`) |
| `MAC mismatch` | the file was edited outside sops (an editor, a formatter, a pre-commit hook) -- restore it from git |
| Flux: `no matches for kind "ENC[AES256_GCM,...]"` | the Kustomization applying the file has no `decryption` block (a layer does not inherit flux-system's) |
| Flux: decryption error | `flux-system/sops-age` holds a key that is not a recipient (e.g. a cluster key, but the file is only encrypted for the master key: `sops updatekeys`) |
