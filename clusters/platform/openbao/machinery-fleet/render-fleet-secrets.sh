#!/usr/bin/env bash
# Renders the credential Secrets of machinery-hv's fleet state and encrypts them
# straight into clusters/machinery-hv-fleet-state/secrets/. Nothing is written
# in plain text: every manifest goes from python's stdout into `sops --encrypt`
# on stdin.
#
# Two sources:
#   step A  the ansible login (from vms/machinery-hv.params.enc.yaml) and the
#           two kubeconfigs of the clusters machinery-hv drives
#   step C  the AppRoles from `terraform output -json approles` in this
#           directory -- run `terraform apply` first
#
# Re-run after rotating an AppRole (taint its secret_id, apply) and commit the
# changed files. Idempotent otherwise: sops re-encrypts with a fresh data key,
# so every file changes on every run -- commit only what you meant to rotate.
#
#   cd clusters/platform/openbao/machinery-fleet
#   ./render-fleet-secrets.sh            # both steps
#   ./render-fleet-secrets.sh A          # one step
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
out="$repo/clusters/machinery-hv-fleet-state/secrets"
recipient="age19vgzvmpt9tdlcsu8rzaacj397yz8gguz38nsmuy6eeelt5vjsyms542xtm" # pragma: allowlist secret -- the PUBLIC age recipient
openbao="https://openbao.platform.sthings.lab"
steps="${1:-AC}"

mkdir -p "$out"

# enc <file> : encrypt the manifest on stdin to $out/<file>
enc() {
  sops --encrypt --age "$recipient" --input-type yaml --output-type yaml \
    /dev/stdin > "$out/$1"
  echo "  wrote secrets/$1"
}

# secret <namespace> <name> <key=value-from-env-var>... : a Secret manifest on
# stdout. Values are passed by ENVIRONMENT VARIABLE NAME, not on the command
# line, so they never show up in `ps`.
secret() {
  python3 - "$@" <<'PY'
import os, sys, yaml
ns, name, *pairs = sys.argv[1:]
data = {k: os.environ[v] for k, v in (p.split("=", 1) for p in pairs)}
print(yaml.safe_dump({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                      "metadata": {"name": name, "namespace": ns},
                      "stringData": data}, sort_keys=False))
PY
}

if [[ "$steps" == *A* ]]; then
  echo "step A: ansible login and kubeconfigs"
  params="$repo/vms/machinery-hv.params.enc.yaml"
  # The cloud-init login IS the ansible login: cloud-init's chpasswd sets it on
  # every VM the golden image boots, so no other pair can work.
  A_USER=$(sops -d --extract '["cloudInitUsername"]' "$params")
  A_PASS=$(sops -d --extract '["cloudInitPassword"]' "$params")
  HV_KUBECONFIG=$(cat "$HOME/.kube/harvester")
  RANCHER_KUBECONFIG=$(cat "$HOME/.kube/platform.sthings.lab")
  export A_USER A_PASS HV_KUBECONFIG RANCHER_KUBECONFIG

  secret tekton-ci ansible-credentials ANSIBLE_USER=A_USER ANSIBLE_PASSWORD=A_PASS \
    | enc ansible-credentials.enc.yaml
  secret crossplane-system harvester-kubeconfig kubeconfig=HV_KUBECONFIG \
    | enc harvester-kubeconfig.enc.yaml
  secret crossplane-system rancher-mgmt-kubeconfig kubeconfig=RANCHER_KUBECONFIG \
    | enc rancher-mgmt-kubeconfig.enc.yaml
fi

if [[ "$steps" == *C* ]]; then
  echo "step C: AppRole credentials from terraform output"
  roles=$(cd "$here" && terraform output -json approles)
  get() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]][sys.argv[3]])' "$roles" "$1" "$2"; }

  # role -> the three shapes it is consumed in (see the fleet-state README):
  #   crossplane-system/<creds>  provider-vault `credentials` JSON
  #   default/<tfvars>           OpenTofu Workspace varFile
  #   tekton-ci/vault            the join play's kubeconfig upload (kubeconfig-writer only)
  for spec in \
    "crossplane:vault-provider-creds:vault-approle" \
    "machinery-hv-cluster-secrets-writer:vault-creds-cluster-secrets:vault-cluster-secrets-writer" \
    "machinery-hv-kubeconfig-writer:vault-creds-kubeconfig-writer:vault-kubeconfig-writer"; do
    IFS=: read -r role creds tfvars <<<"$spec"
    ROLE_ID=$(get "$role" role_id)
    SECRET_ID=$(get "$role" secret_id)
    CREDS=$(python3 -c 'import json,sys; print(json.dumps({"auth_login":{"path":"auth/approle/login","parameters":{"role_id":sys.argv[1],"secret_id":sys.argv[2]}}}))' "$ROLE_ID" "$SECRET_ID")
    TFVARS=$(printf 'vault_role_id = "%s"\nvault_secret_id = "%s"\n' "$ROLE_ID" "$SECRET_ID")
    export ROLE_ID SECRET_ID CREDS TFVARS

    secret crossplane-system "$creds" credentials=CREDS | enc "$creds.enc.yaml"
    secret default "$tfvars" terraform.tfvars=TFVARS | enc "$tfvars.enc.yaml"

    if [[ "$role" == "machinery-hv-kubeconfig-writer" ]]; then
      # Named `vault` on purpose: ClusterStack.spec.kubeconfig.vaultSecretName
      # defaults to it, and the READ side is derived from that name
      # (`vault` -> ClusterProviderConfig `vault-kubeconfigs`). Any other name
      # needs providerConfigRef set by hand on every order.
      VAULT_ADDR_V="$openbao"
      export VAULT_ADDR_V
      secret tekton-ci vault VAULT_ADDR=VAULT_ADDR_V VAULT_ROLE_ID=ROLE_ID VAULT_SECRET_ID=SECRET_ID \
        | enc vault.enc.yaml
    fi
  done
fi
