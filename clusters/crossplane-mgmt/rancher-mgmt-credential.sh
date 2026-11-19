#!/usr/bin/env bash
# Moves crossplane-mgmt's `rancher-mgmt` ClusterProviderConfig from platform's
# ADMIN kubeconfig to the scoped ServiceAccount crossplane-mgmt
# (../platform/crossplane-mgmt-access.yaml), harvester#350.
#
# Nothing here runs by itself and nothing is printed: the kubeconfig goes from
# python's stdout straight into `kubectl apply` on stdin.
#
#   ./rancher-mgmt-credential.sh check     # read-only: token exists, can-i, whoami
#   ./rancher-mgmt-credential.sh secret    # writes crossplane-system/rancher-mgmt-kubeconfig-scoped
#   ./rancher-mgmt-credential.sh switch    # points rancher-mgmt at that Secret
#   ./rancher-mgmt-credential.sh verify    # Objects Synced/Ready, Cluster generation unchanged
#   ./rancher-mgmt-credential.sh rollback  # points rancher-mgmt back at rancher-mgmt-kubeconfig
#
# The OLD Secret rancher-mgmt-kubeconfig is left in place by `switch`, which is
# what makes `rollback` a one-line patch. Delete it only after the soak (see
# README) -- and note its kubectl.kubernetes.io/last-applied-configuration
# annotation holds a second copy of the admin kubeconfig, so it has to be
# deleted, not just emptied.
set -euo pipefail

pk="${PLATFORM_KUBECONFIG:-$HOME/.kube/platform.sthings.lab}"
xk="${CROSSPLANE_KUBECONFIG:-$HOME/.kube/crossplane-mgmt}"
sa_ns=crossplane-mgmt-access
sa=crossplane-mgmt
new_secret=rancher-mgmt-kubeconfig-scoped  # pragma: allowlist secret
old_secret=rancher-mgmt-kubeconfig  # pragma: allowlist secret

render() {
  # The admin kubeconfig is used only to READ the ServiceAccount's token; server
  # and CA come from the same place.
  SA_TOKEN=$(kubectl --kubeconfig "$pk" -n "$sa_ns" get secret "$sa-token" -o jsonpath='{.data.token}' | base64 -d)
  SA_CA=$(kubectl --kubeconfig "$pk" -n "$sa_ns" get secret "$sa-token" -o jsonpath='{.data.ca\.crt}')
  SA_SERVER=$(kubectl --kubeconfig "$pk" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  [[ -n "$SA_TOKEN" && -n "$SA_CA" && -n "$SA_SERVER" ]] || { echo "$sa_ns/$sa-token not found on platform -- is crossplane-mgmt-access.yaml reconciled?" >&2; exit 1; }
  export SA_TOKEN SA_CA SA_SERVER sa
  python3 -c 'import os,yaml; print(yaml.safe_dump({"apiVersion":"v1","kind":"Config","clusters":[{"name":"platform","cluster":{"server":os.environ["SA_SERVER"],"certificate-authority-data":os.environ["SA_CA"]}}],"users":[{"name":os.environ["sa"],"user":{"token":os.environ["SA_TOKEN"]}}],"contexts":[{"name":"platform","context":{"cluster":"platform","user":os.environ["sa"]}}],"current-context":"platform"}, sort_keys=False))'
}

case "${1:-}" in
  check)
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; chmod 600 "$tmp"
    render > "$tmp"
    echo "whoami: $(kubectl --kubeconfig "$tmp" auth whoami -o jsonpath='{.status.userInfo.username}')"
    for c in "patch clusters.provisioning.cattle.io/tabletennis -n fleet-default" \
             "patch harvesterconfigs.rke-machine-config.cattle.io/tabletennis-pool1 -n fleet-default" \
             "patch secrets/tabletennis-kubeconfig -n fleet-default" \
             "patch secrets/tabletennis-argocd-kubeconfig -n argocd" \
             "patch clusterbookclusters.clusterbook.stuttgart-things.com/tabletennis" \
             "get secrets/cc-cl944 -n cattle-global-data" \
             "get secrets -n openbao" \
             "get secrets -n cattle-system"; do
      # shellcheck disable=SC2086
      printf '%-80s %s\n' "$c" "$(kubectl --kubeconfig "$tmp" auth can-i $c 2>/dev/null || true)"
    done
    echo "expected: the first six yes, the last two no"
    ;;
  secret)
    KC=$(render); export KC
    # --server-side: no last-applied-configuration annotation, i.e. no second
    # copy of the credential in the object's metadata.
    python3 -c 'import os,yaml; print(yaml.safe_dump({"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"'"$new_secret"'","namespace":"crossplane-system"},"stringData":{"kubeconfig":os.environ["KC"]}}))' \
      | kubectl --kubeconfig "$xk" apply --server-side --field-manager=harvester-350 -f -
    ;;
  switch)
    kubectl --kubeconfig "$xk" patch clusterproviderconfigs.kubernetes.m.crossplane.io rancher-mgmt --type merge \
      -p '{"spec":{"credentials":{"secretRef":{"name":"'"$new_secret"'"}}}}'
    ;;
  rollback)
    kubectl --kubeconfig "$xk" patch clusterproviderconfigs.kubernetes.m.crossplane.io rancher-mgmt --type merge \
      -p '{"spec":{"credentials":{"secretRef":{"name":"'"$old_secret"'"}}}}'
    ;;
  verify)
    kubectl --kubeconfig "$xk" get clusterproviderconfigs.kubernetes.m.crossplane.io rancher-mgmt -o jsonpath='{.spec.credentials.secretRef.name}{"\n"}'
    kubectl --kubeconfig "$xk" get objects.kubernetes.m.crossplane.io -A -o json \
      | jq -r '.items[] | select(.spec.providerConfigRef.name=="rancher-mgmt") | [.metadata.name, .spec.forProvider.manifest.kind, ((.status.conditions//[])|map("\(.type)=\(.status)")|join(","))] | @tsv'
    kubectl --kubeconfig "$pk" -n fleet-default get clusters.provisioning.cattle.io tabletennis -o jsonpath='generation={.metadata.generation}{"\n"}'
    kubectl --kubeconfig "$pk" -n fleet-default get machines.cluster.x-k8s.io -l cluster.x-k8s.io/cluster-name=tabletennis
    echo "expected: secretRef $new_secret, every Object Synced=True,Ready=True, generation and machine name unchanged from before the switch"
    ;;
  *)
    sed -n '2,19p' "$0"; exit 2 ;;
esac
