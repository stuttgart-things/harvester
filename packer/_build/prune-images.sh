#!/usr/bin/env bash
set -euo pipefail

# Report — and, on explicit opt-in, delete — superseded versioned
# VirtualMachineImages on Harvester.
#
# Images are registered under a versioned name and never replaced (see
# register-image.sh), so every build leaves the previous one behind, each
# holding a Longhorn backing image.
#
# DELETING AN IMAGE IS DESTRUCTIVE: its per-image backing class (lh-<uuid>)
# backs the boot disks of every VM created from it. So this script
#
#   * DEFAULTS TO A DRY RUN. Set PRUNE_DRY_RUN=false to actually delete.
#   * FAILS CLOSED. Any check it cannot complete aborts the run instead of
#     assuming the image is unused — an API error must never read as "safe to
#     delete".
#
# An image goes only when ALL of these hold:
#   * its name is versioned: <base>-<YY.MDD.HHMM>, optionally with a pr<N>.
#     prefix on the version. Unversioned images (sthings-u26, u26-dev, ...) are
#     NEVER touched.
#   * no PersistentVolumeClaim uses its storage class.
#   * it is not referenced by an imageId in PIN_FILE.
#   * it is expendable by the rule for its kind:
#       - PR images (pr<N>. in the version) are built per PR build and are
#         throwaway. They are expendable once PR <N> is no longer open. KEEP
#         does not protect them — there are only ever one or two per base, so
#         treating them as "recent versions" would keep them forever, which is
#         the opposite of what they are for.
#       - release images (no pr<N>.) are kept if they are among the KEEP newest
#         of their base.
#     Determining a PR's state needs the gh CLI. Without it PR images fall back
#     to the KEEP rule, and the run says so rather than guessing them away.
#
# Required env:
#   HARVESTER_VIP       Harvester endpoint (host, no scheme)
#   HARVESTER_PASSWORD  admin password
# Optional:
#   NAMESPACE           Harvester namespace (default: default)
#   KEEP                newest versioned images kept per base (default: 3)
#   PIN_FILE            manifest whose imageIds are protected
#   PRUNE_DRY_RUN       "false" to delete; anything else reports only

NAMESPACE="${NAMESPACE:-default}"
KEEP="${KEEP:-3}"
PRUNE_DRY_RUN="${PRUNE_DRY_RUN:-true}"
PIN_FILE="${PIN_FILE:-../../clusters/crossplane-mgmt/platform/virtual-machine/env-config-virtualmachine.yaml}"

: "${HARVESTER_VIP:?HARVESTER_VIP is required}"
: "${HARVESTER_PASSWORD:?HARVESTER_PASSWORD is required}"

API="https://${HARVESTER_VIP}/v1/harvester"

if [ "${PRUNE_DRY_RUN}" = "false" ]; then
  echo "MODE: deleting (PRUNE_DRY_RUN=false)"
else
  echo "MODE: dry run — nothing will be deleted. Set PRUNE_DRY_RUN=false to act."
fi

echo "Authenticating against Harvester at ${HARVESTER_VIP}..."
TOKEN=$(curl -sk -X POST "https://${HARVESTER_VIP}/v3-public/localProviders/local?action=login" \
  -H 'content-type: application/json' \
  -d '{"username":"admin","password":"'"${HARVESTER_PASSWORD}"'"}' | jq -r '.token')

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "ERROR: Failed to authenticate against Harvester"
  exit 1
fi

# --- What is in use -------------------------------------------------------
# A PVC on an image's storage class means a VM disk was built from it. If this
# list cannot be read we do not know what is in use, and an empty result would
# make everything look prunable — so abort rather than guess.
echo "Reading PersistentVolumeClaims..."
PVC_JSON=$(curl -sk -H "Authorization: Bearer ${TOKEN}" "${API}/persistentvolumeclaims" || true)
if ! jq -e 'has("data")' <<<"${PVC_JSON}" >/dev/null 2>&1; then
  echo "ERROR: could not read PVCs from ${API}/persistentvolumeclaims — refusing to prune."
  echo "Without this list an in-use image cannot be told from a stale one."
  echo "--- response ---"
  head -c 400 <<<"${PVC_JSON}"; echo
  exit 1
fi
USED_CLASSES=$(jq -r '.data[]?.spec.storageClassName // empty' <<<"${PVC_JSON}" | sort -u)
echo "  storage classes in use: $(grep -c . <<<"${USED_CLASSES}" || true)"

# --- What is pinned -------------------------------------------------------
# A freshly pinned image may have no PVC yet, because nothing has been built
# from it since the pin moved. The PVC check alone would not protect it.
if [ ! -f "${PIN_FILE}" ]; then
  echo "ERROR: PIN_FILE not found: ${PIN_FILE}"
  echo "It is the only thing protecting an image nothing has booted from yet."
  exit 1
fi
PINNED=$(grep -oE 'imageId:[[:space:]]*[^[:space:]]+' "${PIN_FILE}" \
  | sed -E 's/.*imageId:[[:space:]]*//; s#^[^/]+/##' | sort -u)
echo "  pinned images from ${PIN_FILE##*/}: $(grep -c . <<<"${PINNED}" || true)"

# --- Candidates -----------------------------------------------------------
echo "Reading VirtualMachineImages in ${NAMESPACE}..."
IMG_JSON=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${API}/harvesterhci.io.virtualmachineimages" || true)
if ! jq -e 'has("data")' <<<"${IMG_JSON}" >/dev/null 2>&1; then
  echo "ERROR: could not list images — aborting."
  exit 1
fi

ALL=$(jq -r --arg ns "${NAMESPACE}" '
  .data[]?
  | select(.metadata.namespace == $ns)
  | [.metadata.name, .metadata.creationTimestamp, (.status.storageClassName // "")]
  | @tsv' <<<"${IMG_JSON}")

VERSION_RE='^(.+)-((pr[0-9]+\.)?[0-9]{2}\.[0-9]{3,4}\.[0-9]{4})$'
TAB=$(printf '\t')

BASES=$(awk -F'\t' '{print $1}' <<<"${ALL}" \
  | grep -E "${VERSION_RE}" | sed -E "s/${VERSION_RE}/\1/" | sort -u || true)

if [ -z "${BASES}" ]; then
  echo "No versioned images found — nothing to prune."
  exit 0
fi

GONE=0
KEPT=0

# PR images are only expendable if we can establish their PR is closed.
GH_REPO_SLUG="${GITHUB_REPOSITORY:-stuttgart-things/harvester}"
HAVE_GH=false
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  HAVE_GH=true
else
  echo
  echo "NOTE: gh unavailable or not authenticated — PR images fall back to the"
  echo "      KEEP rule, which in practice keeps them. Run where gh works to"
  echo "      clean up per-PR images."
fi

# Cache PR states so a base with several images does not re-query one PR.
declare -A PR_STATE=()
pr_is_closed() { # $1 = PR number; 0 = closed/merged, 1 = open or unknown
  local n="$1"
  [ "${HAVE_GH}" = "true" ] || return 1
  if [ -z "${PR_STATE[$n]:-}" ]; then
    PR_STATE[$n]="$(gh pr view "$n" --repo "${GH_REPO_SLUG}" --json state -q .state 2>/dev/null || echo UNKNOWN)"
  fi
  case "${PR_STATE[$n]}" in
    MERGED|CLOSED) return 0 ;;
    *) return 1 ;;
  esac
}

for base in ${BASES}; do
  echo
  echo "== ${base} =="
  # Newest first, so the KEEP newest are simply the head of the list.
  GROUP=$(grep -E "^${base}-((pr[0-9]+\.)?[0-9]{2}\.[0-9]{3,4}\.[0-9]{4})${TAB}" <<<"${ALL}" \
    | sort -t"${TAB}" -k2,2r || true)

  idx=0
  while IFS=$'\t' read -r name created sc; do
    [ -z "${name}" ] && continue

    # PR number, if this is a per-PR image.
    PRNUM=$(sed -nE "s/^${base}-pr([0-9]+)\..*/\1/p" <<<"${name}")

    if [ -n "${PRNUM}" ]; then
      if ! pr_is_closed "${PRNUM}"; then
        if [ "${HAVE_GH}" = "true" ]; then
          echo "  KEEP    ${name}  — PR #${PRNUM} is still open"
        else
          echo "  KEEP    ${name}  — PR #${PRNUM} state unknown (no gh)"
        fi
        KEPT=$((KEPT + 1)); continue
      fi
      # Closed PR: expendable, subject to the safety checks below.
    else
      # Release image: KEEP protects the newest few. The index counts release
      # images only, so throwaway PR images cannot occupy a keep slot.
      idx=$((idx + 1))
      if [ "${idx}" -le "${KEEP}" ]; then
        echo "  keep    ${name}  (newest ${idx}/${KEEP})"
        KEPT=$((KEPT + 1)); continue
      fi
    fi

    if grep -qx "${name}" <<<"${PINNED}"; then
      echo "  KEEP    ${name}  — pinned in ${PIN_FILE##*/}"
      KEPT=$((KEPT + 1)); continue
    fi
    if [ -z "${sc}" ]; then
      # Still importing, or in a bad state. Either way the in-use check cannot
      # be trusted for it.
      echo "  KEEP    ${name}  — no storageClassName reported, cannot verify it is unused"
      KEPT=$((KEPT + 1)); continue
    fi
    if grep -qx "${sc}" <<<"${USED_CLASSES}"; then
      echo "  KEEP    ${name}  — ${sc} backs a live PVC"
      KEPT=$((KEPT + 1)); continue
    fi

    if [ "${PRUNE_DRY_RUN}" != "false" ]; then
      echo "  WOULD DELETE ${name}  (${created})"
      GONE=$((GONE + 1)); continue
    fi

    echo "  delete  ${name}  (${created})"
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer ${TOKEN}" \
      "${API}/harvesterhci.io.virtualmachineimages/${NAMESPACE}/${name}" || true)
    case "${CODE}" in
      2*) GONE=$((GONE + 1)) ;;
      *)
        # Harvester refusing a delete is a signal, not noise — it knows about
        # references this script cannot see. Report it and move on.
        echo "    WARNING: delete returned HTTP ${CODE:-<none>} — left in place"
        KEPT=$((KEPT + 1))
        ;;
    esac
  done <<< "${GROUP}"
done

echo
if [ "${PRUNE_DRY_RUN}" != "false" ]; then
  echo "Dry run: ${GONE} image(s) would be deleted, ${KEPT} kept."
  echo "Re-run with PRUNE_DRY_RUN=false to delete them."
else
  echo "Pruned ${GONE} image(s), kept ${KEPT}."
fi
