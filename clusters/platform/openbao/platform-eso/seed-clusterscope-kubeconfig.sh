#!/usr/bin/env bash
# Seed ONE cluster's read-only kubeconfig for clusterscope into OpenBao
# (KV mount `clusterscope`, entry <name>, property `kubeconfig`; harvester#753).
#
#   ./seed-clusterscope-kubeconfig.sh <name> <admin-kubeconfig> [server-url]
#
#   <name>              the cluster's name in clusterscope = its directory under
#                       clusters/ (app-dev-hv has none: it shows as
#                       "kubeconfig only")
#   <admin-kubeconfig>  a kubeconfig that may create RBAC on that cluster; it
#                       is used for the apply below and NOT stored anywhere
#   [server-url]        API URL as platform's pods reach it; default = the
#                       admin kubeconfig's server
#
# What it does, in this order:
#   1. applies ServiceAccount + ClusterRole + ClusterRoleBinding
#      `clusterscope-reader` and a long-lived token Secret in kube-system --
#      get/list/watch on exactly what clusterscope reads (its own ClusterRole,
#      clusterscope kcl/clusterrole.k, plus ClusterStacks for the order view).
#      No Secrets, no writes. `kubectl delete secret clusterscope-reader-token
#      -n kube-system` revokes it.
#   2. builds a kubeconfig from that token + the cluster CA (umask 077 temp
#      file, deleted on exit), proves it can list pods and can NOT read Secrets
#   3. writes it to OpenBao with the token in ~/.vaulttoken (or VAULT_TOKEN)
#
# Nothing secret is printed. Re-running is safe: the apply is idempotent and
# OpenBao keeps the previous version.
set -euo pipefail

NAME=${1:?usage: $0 <name> <admin-kubeconfig> [server-url]}
ADMIN_KUBECONFIG=${2:?usage: $0 <name> <admin-kubeconfig> [server-url]}
SERVER=${3:-}
VAULT_ADDR=${VAULT_ADDR:-https://openbao.platform.sthings.lab}
VAULT_TOKEN=${VAULT_TOKEN:-$(cat ~/.vaulttoken)}
MOUNT=${MOUNT:-clusterscope}

[[ "$NAME" =~ ^[a-z0-9-]+$ ]] || { echo "name must match ^[a-z0-9-]+\$" >&2; exit 1; }
[[ -r "$ADMIN_KUBECONFIG" ]] || { echo "cannot read $ADMIN_KUBECONFIG" >&2; exit 1; }
k() { kubectl --kubeconfig "$ADMIN_KUBECONFIG" "$@"; }

if [[ -z "$SERVER" ]]; then
  SERVER=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')
fi

echo "1/3 RBAC clusterscope-reader on $NAME ($SERVER)"
k apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: clusterscope-reader
  namespace: kube-system
  labels:
    app.kubernetes.io/name: clusterscope-reader
    app.kubernetes.io/part-of: clusterscope
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: clusterscope-reader
  labels:
    app.kubernetes.io/name: clusterscope-reader
    app.kubernetes.io/part-of: clusterscope
rules:
  - apiGroups: [""]
    resources: [nodes, namespaces, pods, configmaps]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, replicasets, statefulsets, daemonsets]
    verbs: [get, list, watch]
  - apiGroups: [kustomize.toolkit.fluxcd.io]
    resources: [kustomizations]
    verbs: [get, list, watch]
  - apiGroups: [source.toolkit.fluxcd.io]
    resources: [gitrepositories, ocirepositories, helmrepositories, helmcharts]
    verbs: [get, list, watch]
  - apiGroups: [helm.toolkit.fluxcd.io]
    resources: [helmreleases]
    verbs: [get, list, watch]
  - apiGroups: [fluxcd.controlplane.io]
    resources: [fluxinstances]
    verbs: [get, list, watch]
  - apiGroups: [gateway.networking.k8s.io]
    resources: [gateways, httproutes]
    verbs: [get, list, watch]
  - apiGroups: [argoproj.io]
    resources: [applications, applicationsets, appprojects]
    verbs: [get, list, watch]
  # the order view (clusterscope docs/lab.md) on a machinery cluster
  - apiGroups: [config.stuttgart-things.com]
    resources: [clusterstacks]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: clusterscope-reader
  labels:
    app.kubernetes.io/name: clusterscope-reader
    app.kubernetes.io/part-of: clusterscope
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: clusterscope-reader
subjects:
  - kind: ServiceAccount
    name: clusterscope-reader
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: clusterscope-reader-token
  namespace: kube-system
  labels:
    app.kubernetes.io/name: clusterscope-reader
    app.kubernetes.io/part-of: clusterscope
  annotations:
    kubernetes.io/service-account.name: clusterscope-reader
type: kubernetes.io/service-account-token
EOF

TMP=$(umask 077; mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "2/3 build and check the reader kubeconfig"
for _ in $(seq 1 30); do
  TOKEN=$(k -n kube-system get secret clusterscope-reader-token -o jsonpath='{.data.token}' | base64 -d)
  [[ -n "$TOKEN" ]] && break
  sleep 2
done
[[ -n "${TOKEN:-}" ]] || { echo "token Secret was not filled" >&2; exit 1; }
k -n kube-system get secret clusterscope-reader-token -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt"

KC="$TMP/kubeconfig"
KUBECONFIG="$KC" kubectl config set-cluster "$NAME" --server="$SERVER" \
  --certificate-authority="$TMP/ca.crt" --embed-certs=true >/dev/null
KUBECONFIG="$KC" kubectl config set-credentials clusterscope-reader --token="$TOKEN" >/dev/null
KUBECONFIG="$KC" kubectl config set-context "$NAME" --cluster="$NAME" --user=clusterscope-reader >/dev/null
KUBECONFIG="$KC" kubectl config use-context "$NAME" >/dev/null
unset TOKEN

[[ $(kubectl --kubeconfig "$KC" auth can-i list pods -A 2>/dev/null || true) == yes ]] \
  || { echo "reader cannot list pods -- not seeding" >&2; exit 1; }
if [[ $(kubectl --kubeconfig "$KC" auth can-i get secrets -A 2>/dev/null || true) == yes ]]; then
  echo "reader CAN read Secrets -- refusing to seed a kubeconfig that is not read-only" >&2
  exit 1
fi
echo "   list pods: yes, get secrets: no"

echo "3/3 write $MOUNT/$NAME to $VAULT_ADDR"
jq -n --rawfile kc "$KC" '{data: {kubeconfig: $kc}}' > "$TMP/body.json"
curl -sfk -o /dev/null -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  --data @"$TMP/body.json" "$VAULT_ADDR/v1/$MOUNT/data/$NAME"
curl -sfk -o /dev/null -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  --data '{"custom_metadata":{"managed-by":"seed-clusterscope-kubeconfig","cluster":"'"$NAME"'"}}' \
  "$VAULT_ADDR/v1/$MOUNT/metadata/$NAME"
echo "   done: $MOUNT/$NAME"
