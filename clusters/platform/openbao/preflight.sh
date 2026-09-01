#!/usr/bin/env bash
# Preflight for `terraform apply` in this directory.
#
# WHY THIS EXISTS AND A README LINE DOES NOT DO. Every check below compares the
# configuration in this directory against the LIVE cluster. A note in a runbook
# is read once; a variable answered once ends up in terraform.tfvars and is
# wrong the next time the cluster is rebuilt. This runs every time and fails on
# the mismatch itself.
#
#   ./preflight.sh && terraform apply
#
# Exits non-zero on anything that would make the apply fail or -- worse --
# succeed while being wrong.
set -uo pipefail

KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/platform.sthings.lab}"
TF="${TF:-openbao.tf}"
fail=0

say()  { printf '%-58s %s\n' "$1" "$2"; }
bad()  { say "$1" "FAIL"; printf '\n    %s\n\n' "$2"; fail=1; }
ok()   { say "$1" "ok"; }

# ---- 1. cluster reachable --------------------------------------------------
if ! kubectl --kubeconfig="$KUBECONFIG_PATH" get --raw /readyz >/dev/null 2>&1; then
  bad "cluster reachable" \
"kubectl --kubeconfig=$KUBECONFIG_PATH cannot reach the API server.
    Set KUBECONFIG_PATH if the file lives elsewhere."
  echo; echo "Cannot check anything else without the cluster."; exit 1
fi
ok "cluster reachable"

# ---- 2. the reviewer, and whether the config agrees with reality ------------
# blueprints CreateVaultKubernetesAuth creates ServiceAccount, SA-token Secret
# and ClusterRoleBinding under exactly the names vault-base-setup wants. Two
# owners for one identity is not a conflict Terraform resolves: it stops with
# `serviceaccounts "vault-auth-reviewer" already exists`. This is how the
# rehearsal on cicd-test3 failed.
# Comment lines are stripped FIRST. Without that the greps below happily match
# the explanatory comment in openbao.tf that names the very setting they look
# for, and the preflight reports the opposite of the truth -- which is exactly
# what happened the first time this ran.
code=$(grep -vE '^[[:space:]]*(#|//)' "$TF" 2>/dev/null)

reviewer_name=$(printf '%s' "$code" | grep -oP 'k8s_auth_reviewer_name\s*=\s*"\K[^"]+' || true)
reviewer_name="${reviewer_name:-vault-auth-reviewer}"
reviewer_ns=$(printf '%s' "$code" | grep -oP 'k8s_auth_reviewer_namespace\s*=\s*"\K[^"]+' || true)
reviewer_ns="${reviewer_ns:-kube-system}"

# Absent from the file means the module default, which is true.
declared=$(printf '%s' "$code" | grep -oP 'k8s_auth_reviewer_create\s*=\s*\K(true|false)' | head -1 || true)
declared="${declared:-true}"

if kubectl --kubeconfig="$KUBECONFIG_PATH" -n "$reviewer_ns" \
     get sa "$reviewer_name" >/dev/null 2>&1; then
  exists=true
else
  exists=false
fi

# The config must say "create" exactly when the reviewer is NOT already there.
if [ "$exists" = true ] && [ "$declared" = true ]; then
  bad "reviewer $reviewer_ns/$reviewer_name" \
"It already exists -- something else owns it, almost certainly the VM
    pipeline's CreateVaultKubernetesAuth. The apply will stop with
    'serviceaccounts \"$reviewer_name\" already exists'.

    Add to $TF:   k8s_auth_reviewer_create = false"
elif [ "$exists" = false ] && [ "$declared" = false ]; then
  bad "reviewer $reviewer_ns/$reviewer_name" \
"$TF says k8s_auth_reviewer_create = false, but no such ServiceAccount
    exists. Nothing would create it, and the apply fails reading its Secret.

    Remove that line from $TF, or create the reviewer first."
else
  ok "reviewer $reviewer_ns/$reviewer_name (exists=$exists, create=$declared)"
fi

# ---- 3. OpenBao initialised and unsealed ------------------------------------
# The static seal unseals on every RESTART but does not INITIALISE. An
# uninitialised instance answers, so terraform fails deep in the apply rather
# than up front.
# The variable's default, i.e. the only URL-shaped default in the file. VAULT_ADDR
# wins, which is what a port-forward needs.
addr=$(printf '%s' "$code" | grep -oP 'default\s*=\s*"\Khttps?://[^"]+' | head -1)
addr="${VAULT_ADDR:-${addr:-}}"
if [ -z "$addr" ]; then
  bad "openbao address" "Neither VAULT_ADDR nor a default in $TF."
else
  health=$(curl -sk --max-time 10 "$addr/v1/sys/health" 2>/dev/null || true)
  case "$health" in
    *'"initialized":true'*'"sealed":false'*) ok "openbao at $addr" ;;
    *'"initialized":false'*)
      bad "openbao at $addr" \
"Initialized=false. Run 'bao operator init' once -- see README.md step 2.
    The static seal unseals on restart; it does not initialise." ;;
    *'"sealed":true'*)
      bad "openbao at $addr" "Sealed. The static seal Secret is missing or wrong." ;;
    "") bad "openbao at $addr" "No answer. If the hostname does not resolve here:
    kubectl -n openbao port-forward svc/openbao 18200:8200
    export VAULT_ADDR=http://127.0.0.1:18200" ;;
    *)  bad "openbao at $addr" "Unexpected /sys/health response: $health" ;;
  esac
fi

# ---- 4. a token that can actually do the work -------------------------------
if [ -z "${VAULT_TOKEN:-}" ]; then
  bad "VAULT_TOKEN" "Not set. The root token from 'bao operator init'."
elif [ -n "${addr:-}" ]; then
  if curl -sk --max-time 10 -H "X-Vault-Token: $VAULT_TOKEN" \
       "$addr/v1/auth/token/lookup-self" 2>/dev/null | grep -q '"errors"'; then
    bad "VAULT_TOKEN" "Rejected by $addr. Revoked already, or from another instance."
  else
    ok "VAULT_TOKEN accepted"
  fi
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "preflight FAILED -- do not apply."
  exit 1
fi
echo "preflight ok -- safe to run terraform apply."
