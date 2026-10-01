#!/usr/bin/env bash
set -euo pipefail

# Fail the build when cloud-init did not finish cleanly or a package from
# packages.yaml is missing (harvester#314).
#
# WHY. packages.yaml goes straight into cloud-init's `packages:` list, and
# cloud-init installs that list with ONE package-manager call. A single unknown
# name ("Unable to locate package") makes the whole call fail, so NOTHING from
# the list lands -- including qemu-guest-agent, which Harvester needs to report
# a VM's IP. cloud-init only logs that and still writes boot-finished, the one
# marker the wait provisioner looks at. Without this script the build was green,
# the PR auto-merged and the pin bot moved the alias to a broken image.
#
# Two checks, in this order:
#
#   1. `cloud-init status --wait`
#        0  done, no errors              -> ok
#        1  error (a module failed)      -> FAIL
#        2  done, recoverable errors     -> warning only. cloud-init >= 23.4
#           returns 2 for deprecation warnings too, so failing on it would turn
#           builds red for reasons that have nothing to do with the image.
#           Check 2 below catches the case that matters either way.
#   2. every entry in packages.yaml is installed: dpkg-query on Debian/Ubuntu,
#      `rpm -q --whatprovides` on Rocky/Leap (so capability names work too).
#      This names the missing package in the log.
#
# Env:
#   PACKAGES  space-separated package names from packages.yaml (may be empty)

PACKAGES="${PACKAGES:-}"
failed=0

echo "== cloud-init status =="
rc=0
sudo cloud-init status --wait --long || rc=$?
case "${rc}" in
  0) echo "cloud-init: done, no errors." ;;
  2) echo "WARNING: cloud-init finished with recoverable errors (exit 2) -- see the status above." ;;
  *)
    echo "ERROR: cloud-init failed (exit ${rc})."
    failed=1
    ;;
esac

echo "== packages from packages.yaml =="
if [ -z "${PACKAGES}" ]; then
  echo "packages.yaml lists no packages -- nothing to check."
else
  missing=()
  no_tool=0
  for pkg in ${PACKAGES}; do
    if command -v dpkg-query >/dev/null 2>&1; then
      status="$(dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null || true)"
      [ "${status}" = "install ok installed" ] || missing+=("${pkg}")
    elif command -v rpm >/dev/null 2>&1; then
      rpm -q --whatprovides "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
    else
      echo "ERROR: neither dpkg-query nor rpm found -- cannot check packages."
      failed=1
      no_tool=1
      break
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: not installed: ${missing[*]}"
    echo "Check the names in packages.yaml. One unknown name makes cloud-init skip the WHOLE list."
    failed=1
  elif [ "${no_tool}" -eq 0 ]; then
    echo "all installed: ${PACKAGES}"
  fi
fi

if [ "${failed}" -ne 0 ]; then
  echo "== last lines of /var/log/cloud-init-output.log =="
  sudo tail -n 40 /var/log/cloud-init-output.log 2>/dev/null || true
  exit 1
fi
