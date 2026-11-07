#!/bin/sh
# Healthy means all three layers are actually up, not just that the process runs:
# the tunnel, the redirect policy, and a bootstrapped Tor circuit. The notices
# log lives on tmpfs, so "Bootstrapped 100%" cannot be a leftover from a
# previous run.
set -eu

ip link show wg0 >/dev/null 2>&1   || { echo "wg0 interface missing"; exit 1; }
wg show wg0 >/dev/null 2>&1        || { echo "wg0 not configured"; exit 1; }
nft list table inet onionvpn >/dev/null 2>&1 \
    || { echo "nftables policy missing — clients would have no route"; exit 1; }

if ! grep -q "Bootstrapped 100%" /run/tor/notices.log 2>/dev/null; then
    echo "tor not bootstrapped yet: $(tail -n1 /run/tor/notices.log 2>/dev/null || echo 'no log yet')"
    exit 1
fi
echo "ok: wg0 up, policy loaded, tor bootstrapped"
