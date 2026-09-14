#!/usr/bin/env bash
set -euo pipefail

# Prefer IPv4 over IPv6 for dual-stack destinations, at BUILD time, so every VM
# from this image inherits it.
#
# WHY. The RA on the lab network hands out SEVERAL simultaneous global IPv6
# prefixes, and they rotate. With the default (empty) /etc/gai.conf, RFC 6724
# picks IPv6 for any dual-stack destination -- and there is no fallback to IPv4,
# because IPv6 is *reachable*. What breaks is large transfers from a source
# address whose prefix has gone stale: the connection resets mid-copy while small
# requests over the exact same path succeed.
#
# Measured on the platform node 2026-09-14, pulling a container image:
#
#   failed to copy: read tcp [2a01:599:b45:8028:...]:43460
#                        -> [2600:9000:2133:2400:...]:443: read: connection reset by peer
#   curl -6 https://registry-1.docker.io/v2/  ->  401 in 0.85s   (small request: fine)
#
# The node carried four global IPv6 addresses at the time. After setting the
# precedence line below, `getent ahosts registry-1.docker.io` returned an IPv4
# address first and the same pull finished in seconds.
#
# This is a WORKAROUND for an unstable IPv6 environment, not a statement that
# IPv6 is unwanted. If the RA is ever fixed to hand out one stable prefix, drop
# it -- set PREFER_IPV4=false to skip.
#
# Env:
#   PREFER_IPV4  "true" (default) or "false" to skip

PREFER_IPV4="${PREFER_IPV4:-true}"
GAI_CONF="/etc/gai.conf"
MARKER="precedence ::ffff:0:0/96"

if [ "${PREFER_IPV4}" != "true" ]; then
  echo "PREFER_IPV4=${PREFER_IPV4} -- leaving ${GAI_CONF} alone."
  exit 0
fi

if [ ! -e "${GAI_CONF}" ]; then
  echo "${GAI_CONF} does not exist, creating it."
  sudo touch "${GAI_CONF}"
fi

# Idempotent: a rebuilt image or a re-run must not stack duplicate lines, and a
# duplicate precedence entry is not harmless -- glibc reads them in order.
if grep -qE "^[[:space:]]*${MARKER}" "${GAI_CONF}"; then
  echo "${GAI_CONF} already prefers IPv4, nothing to do."
else
  sudo tee -a "${GAI_CONF}" >/dev/null <<'EOF'

# Prefer IPv4 for dual-stack destinations. The lab RA hands out several
# simultaneous global IPv6 prefixes; a source address from a stale one makes
# large transfers reset mid-copy while small requests succeed. Set at image
# build time -- see packer/_build/prefer-ipv4.sh.
precedence ::ffff:0:0/96  100
EOF
  echo "Added IPv4 precedence to ${GAI_CONF}."
fi

echo "--- ${GAI_CONF} (effective lines) ---"
grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${GAI_CONF}" || true
