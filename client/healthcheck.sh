#!/bin/sh
# Healthy means the tunnel is current and still the only way out. A recent
# handshake is the real signal: WireGuard is silent when idle, but the client
# config sets PersistentKeepalive=25, so a gap beyond 180s means the tunnel is
# genuinely gone rather than merely quiet.
set -eu

ip link show wg0 >/dev/null 2>&1 || { echo "wg0 interface missing"; exit 1; }
ip -4 route show default | grep -q 'dev wg0' \
    || { echo "default route is not wg0 — traffic would bypass the tunnel"; exit 1; }
nft list table inet onionvpn_client >/dev/null 2>&1 \
    || { echo "kill-switch missing"; exit 1; }

hs=$(wg show wg0 latest-handshakes | awk '{print $2; exit}')
[ -n "${hs:-}" ] && [ "$hs" -gt 0 ] 2>/dev/null || { echo "no handshake yet"; exit 1; }

age=$(( $(date +%s) - hs ))
[ "$age" -lt 180 ] || { echo "last handshake was ${age}s ago"; exit 1; }
echo "ok: tunnel up, handshake ${age}s ago, kill-switch loaded"
