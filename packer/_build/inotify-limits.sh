#!/usr/bin/env bash
set -euo pipefail

# Raise the inotify limits at BUILD time, so every node from this image has
# them before k3s/rke2 starts.
#
# WHY. Ubuntu ships fs.inotify.max_user_instances = 128 per UID. On a k3s/rke2
# node most of root's instances are taken by containerd, kubelet, the k3s/rke2
# process and every root container that watches files. A DaemonSet that tails
# container logs then cannot get one more:
#
#   [input:tail:tail.0] ... tail_fs_inotify.c:425 errno=24] Too many open files
#   [input:tail:tail.0] failed initialize input tail.0
#
# fluent-bit crash-looped exactly this way on platform and homerun2-dev on
# 2026-10-27 (harvester#499). 8192 instances / 524288 watches are the values
# common for Kubernetes nodes; each watch costs ~1 KiB of kernel memory only
# when used.
#
# Env:
#   INOTIFY_MAX_USER_INSTANCES  default 8192
#   INOTIFY_MAX_USER_WATCHES    default 524288

INSTANCES="${INOTIFY_MAX_USER_INSTANCES:-8192}"
WATCHES="${INOTIFY_MAX_USER_WATCHES:-524288}"
CONF="/etc/sysctl.d/90-inotify.conf"

# Overwrite, not append: the file is ours, and a rebuild must not stack lines.
sudo tee "${CONF}" >/dev/null <<EOF
# Kubernetes node inotify limits -- set at image build time, see
# packer/_build/inotify-limits.sh in stuttgart-things/harvester.
fs.inotify.max_user_instances = ${INSTANCES}
fs.inotify.max_user_watches = ${WATCHES}
EOF

sudo sysctl -p "${CONF}"
echo "--- ${CONF} ---"
cat "${CONF}"
