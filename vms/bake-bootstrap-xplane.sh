#!/usr/bin/env bash
#
# The bootstrap-xplane run, exactly as it is executed. This file is the
# reproducible form of the call documented in vms/README.md -- keep the two in
# step, or better, change this one and let the README point at it.
#
#   ./vms/bake-bootstrap-xplane.sh            # render only, touches no cluster
#   ./vms/bake-bootstrap-xplane.sh apply      # the real run
#
# Requires: dagger, sops, kubectl, python3, and SOPS_AGE_KEY in the
# environment. ANSIBLE_USER/ANSIBLE_PASSWORD are NOT read from the
# environment: they are derived from the encrypted parameters, so the account
# Ansible logs in as is by construction the one cloud-init created. Setting
# them by hand is how you get a VM that boots fine and rejects the playbook.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

MODULE="github.com/stuttgart-things/blueprints/vm@v3.2.1"
VM_NAME="bootstrap-xplane"
NAMESPACE="default"
PARAMS="./vms/${VM_NAME}.params.yaml"
ENC="./vms/${VM_NAME}.params.enc.yaml"
VARS="./vms/${VM_NAME}.ansible-vars.yaml"
KUBECONFIG_FILE="${HARVESTER_KUBECONFIG:-$HOME/.kube/harvester}"
PLAYBOOKS="sthings.baseos.setup"

# v3.2.1 pins harvester-vm 0.3.0, which takes storageClassName verbatim. Do not
# drop to v3.2.0: it pins the 0.2.0 tag, and that tag is mutable -- it currently
# serves the 0.3.0 module, so the same pin resolved to different code before and
# after 2026-09-02. See vms/README.md.

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$PARAMS" ]] || die "missing $PARAMS"

if [[ "${1:-render}" != "apply" ]]; then
  # Deliberately checks nothing else: a render needs no cluster and no key, so
  # it stays usable in CI and on a laptop with no access to Harvester.
  echo "== DRY RUN: rendering only, nothing is applied =="
  exec dagger call -m "$MODULE" render-harvester-vm \
    --kcl-parameters-file "$PARAMS" contents
fi

[[ -f "$ENC" ]]              || die "missing $ENC"
[[ -f "$VARS" ]]             || die "missing $VARS"
[[ -f "$KUBECONFIG_FILE" ]]  || die "no kubeconfig at $KUBECONFIG_FILE (override with HARVESTER_KUBECONFIG)"
[[ -n "${SOPS_AGE_KEY:-}" ]] || die "SOPS_AGE_KEY is not set"

# Read once, not twice: two `sops -d` calls can disagree if the file changes
# underneath, and each one decrypts the credentials again.
eval "$(
  sops -d "$ENC" | python3 -c '
import sys, yaml, shlex
d = yaml.safe_load(sys.stdin)
for key, var in (("cloudInitUsername", "ANSIBLE_USER"), ("cloudInitPassword", "ANSIBLE_PASSWORD")):
    v = d.get(key)
    if not v:
        sys.exit(f"{key} missing from the encrypted parameters")
    print(f"export {var}={shlex.quote(str(v))}")
'
)"

echo "== APPLY: ${VM_NAME} in ${NAMESPACE}, ansible user ${ANSIBLE_USER} =="
dagger call -m "$MODULE" \
  bake-harvester \
  --kube-config "file://${KUBECONFIG_FILE}" \
  --vm-name "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --encrypted-file "$ENC" \
  --sops-key env:SOPS_AGE_KEY \
  --ansible-playbooks "$PLAYBOOKS" \
  --ansible-parameters "$(python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(",".join(f"{k}={str(v).lower() if isinstance(v, bool) else v}" for k, v in d.items()))
' "$VARS")" \
  --ansible-user env:ANSIBLE_USER \
  --ansible-password env:ANSIBLE_PASSWORD \
  --progress plain -vv \
  export --path "/tmp/${VM_NAME}"
