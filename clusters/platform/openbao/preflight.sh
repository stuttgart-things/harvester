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

TF="${TF:-openbao.tf}"
fail=0

# ---- which cluster is this even checking? ----------------------------------
# THIS SCRIPT IS SHARED BY FIVE DIRECTORIES and every check below is a
# comparison against a live cluster, so pointing it at the wrong one makes the
# whole thing worse than useless. The default used to be hardcoded to
# platform.sthings.lab, which is correct in exactly one of those directories.
#
# It bit on 2026-09-08 in clusters/crossplane-mgmt/openbao: run without
# KUBECONFIG_PATH, it reported the reviewer as already existing -- true on
# platform, where platform's own apply had created it, and false on
# crossplane-mgmt. Following that advice (k8s_auth_reviewer_create = false)
# would have told the module to read a ServiceAccount that does not exist.
#
# The other direction is worse and silent: a reviewer present on the TARGET
# cluster but not on platform reports `ok`, and the apply then stops with
# `serviceaccounts "vault-auth-reviewer" already exists` -- the single failure
# this check exists to prevent.
#
# So the default now comes from the same file everything else is read from: the
# `kubeconfig_path` variable in this directory's openbao.tf, which is the value
# terraform itself will use. Comments are stripped first, for the reason given
# at the reviewer check below. The chosen path is printed every run -- an
# unlabelled `ok` is what made this invisible.
tf_kubeconfig=$(awk '
  /^[[:space:]]*(#|\/\/)/           { next }
  /variable[[:space:]]+"kubeconfig_path"/ { inblk = 1 }
  inblk && /default[[:space:]]*=/ {
      if (match($0, /"[^"]+"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
  }
  inblk && /^[[:space:]]*\}/        { inblk = 0 }
' "$TF" 2>/dev/null)

if [ -n "${KUBECONFIG_PATH:-}" ]; then
  kubeconfig_origin="KUBECONFIG_PATH"
elif [ -n "$tf_kubeconfig" ]; then
  KUBECONFIG_PATH="$tf_kubeconfig"
  kubeconfig_origin="$TF"
else
  echo "cannot determine which cluster to check." >&2
  echo "  No kubeconfig_path variable with a default in $TF, and KUBECONFIG_PATH is unset." >&2
  echo "  Set KUBECONFIG_PATH explicitly." >&2
  exit 1
fi

say()  { printf '%-58s %s\n' "$1" "$2"; }
bad()  { say "$1" "FAIL"; printf '\n    %s\n\n' "$2"; fail=1; }
ok()   { say "$1" "ok"; }

printf 'checking cluster: %s  (from %s)\n\n' "$KUBECONFIG_PATH" "$kubeconfig_origin"

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

# ...unless WE already created it. After a successful apply the reviewer exists
# and `create = true` is still correct, because Terraform holds it in state and
# will not try to create it twice. Without this the preflight fails on every
# re-run of an already-applied directory and tells the operator, wrongly, that
# something else owns their own ServiceAccount.
mine=false
if terraform state list 2>/dev/null \
     | grep -q 'kubernetes_service_account_v1\.reviewer'; then
  mine=true
fi

# The config must say "create" exactly when the reviewer is NOT already there.
if [ "$exists" = true ] && [ "$declared" = true ] && [ "$mine" = true ]; then
  ok "reviewer $reviewer_ns/$reviewer_name (exists, in terraform state)"
elif [ "$exists" = true ] && [ "$declared" = true ]; then
  bad "reviewer $reviewer_ns/$reviewer_name" \
"It already exists and is NOT in this directory's terraform state -- so
    something else owns it, almost certainly the VM pipeline's
    CreateVaultKubernetesAuth. The apply will stop with
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
