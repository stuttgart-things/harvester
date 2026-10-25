# Workstation setup

The machine you work from -- a laptop, a VM, a jump host -- with Ansible code
from our collections instead of hand-run `curl | install` lines. Two
playbooks against `localhost`:

| Playbook | What it installs | Needed for |
|---|---|---|
| `sthings.container.docker` | Docker CE + the compose plugin, your user in the `docker` group | the Dagger engine (it runs as a container) |
| `sthings.container.tools` with [`workstation/tools.yaml`](https://github.com/stuttgart-things/harvester/blob/main/workstation/tools.yaml) | `dagger`, `kubectl`, `helm`, `k9s`, `flux`, `sops`, `age`, `age-keygen` into `/usr/local/bin` | every Dagger call ([k3s option 2](edge/k3s.md#deployment-option-2-dagger), [SOPS option 2](sops.md#option-2-dagger)); working with the clusters |

Tested on Ubuntu (amd64). Both are idempotent: rerun them to update after
bumping a version in `workstation/tools.yaml`; a tool already at its target
version is not downloaded again.

## 1. Ansible (once)

The bootstrap: a venv with Ansible and the `sthings.container` collection --
the same venv as [k3s deployment option 1](edge/k3s.md#deployment-option-1-ansible-cli).

```bash
sudo apt-get install -y python3-venv
python3 -m venv ~/ansible-venv
~/ansible-venv/bin/pip install --upgrade "ansible==14.4.0"
~/ansible-venv/bin/ansible-galaxy collection install -r workstation/requirements.yaml --upgrade
~/ansible-venv/bin/ansible-galaxy collection list | grep sthings.container
```

[`workstation/requirements.yaml`](https://github.com/stuttgart-things/harvester/blob/main/workstation/requirements.yaml)
pins `sthings.container` and the community collections it uses -- the same
pins as a cluster's `clusters/<cluster>/k3s/requirements.yaml`, so either file
will do. `--upgrade` replaces an older `sthings.container` already in
`~/.ansible/collections`.

## 2. Docker

```bash
~/ansible-venv/bin/ansible-playbook -i workstation/inventory.ini -K \
  sthings.container.docker -e target_host=workstation \
  -e '{"docker_users": ["'"$USER"'"]}'
```

- `-K` asks for your sudo password (the play runs with `become`).
- `docker_users` defaults to `[sthings]` -- pass your own user, otherwise
  Docker only works with `sudo`.
- The role updates the OS packages first, adds Docker's apt repository and
  installs `docker-ce` + compose. `kind` is off in this playbook.
- The group membership counts from your **next login** (or `newgrp docker`
  in the current shell).

```bash
docker run --rm hello-world
```

## 3. Dagger CLI and the other tools

```bash
~/ansible-venv/bin/ansible-playbook -i workstation/inventory.ini -K \
  sthings.container.tools -e target_host=workstation \
  -e @workstation/tools.yaml
```

`workstation/tools.yaml` holds the versions and a `bin` selection: it
**replaces** the collection's full tool list (dozens of CLIs), so only these
eight are installed. Want one more? Copy its entry from the collection's
`playbooks/vars/tools.yaml` into the file.

```bash
dagger version          # dagger v0.21.10 ...
kubectl version --client; helm version --short; k9s version --short
flux version --client; sops --version; age --version
```

The first `dagger call` pulls and starts the engine container
(`registry.dagger.io/engine:v0.21.10`, managed by the CLI) by itself -- nothing else to set up.

## Optional: the Dagger engine with custom CA certificates

Behind a TLS-inspecting proxy, or to pull from a registry with an internal CA,
the engine needs those CAs. `sthings.container.dagger` puts them into
`~/.config/dagger/ca-certificates` (each fetched from a URL, e.g. a Vault/
OpenBao PKI endpoint) and starts the engine container
`dagger-engine-<version>` with them:

```bash
~/ansible-venv/bin/ansible-playbook -i workstation/inventory.ini \
  sthings.container.dagger -e target_host=workstation \
  -e '{"dagger_ca_certificates": [{"name": "labul-ca.crt", "url": "https://<vault>:8200/v1/pki/ca/pem"}]}'
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `permission denied while trying to connect to the Docker daemon socket` | not in the `docker` group yet: log in again (or `newgrp docker`); `docker_users` did not include your user |
| `failed to list SSH agent identities` on `dagger call` | a stale agent socket -- prefix the call with `env -u SSH_AUTH_SOCK` |
| a tool keeps being re-downloaded | its `version_cmd` output does not contain `target_version` -- check `<tool><version_cmd>` by hand |
| `Missing sudo password` | `-K` forgotten |
