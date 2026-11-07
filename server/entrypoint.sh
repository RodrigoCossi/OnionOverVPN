#!/bin/sh
# OnionOverVPN server entrypoint.
#
# Every address this container uses arrives in the environment, from .env via
# compose. Nothing is hardcoded and nothing is defaulted: a missing value is an
# error, because a silent default here would disagree with the addresses the host
# CLI wrote into the client configs, and the tunnel would come up unusable.
#
# Order matters: the WireGuard address must exist before Tor starts, because every
# Tor listener is bound to it (that binding is what keeps Tor off the bridge
# interface). And the nftables policy must be loaded before the first client packet
# can arrive, so it goes up before Tor accepts anything.
set -eu

log() { printf '[onionvpn-server] %s\n' "$*"; }
die() { printf '[onionvpn-server] ERROR: %s\n' "$*" >&2; exit 1; }

require() {
    eval "value=\${$1:-}"
    [ -n "$value" ] || die "$1 is not set — compose passes it from .env; run 'bin/onionvpn init'"
    printf '%s' "$value"
}

WG_IF=wg0
SRC_CONF=/config/wg0.conf
TEMPLATES=/etc/onionvpn

WG_SERVER_IP=$(require WG_SERVER_IP)
WG_PREFIX=$(require WG_PREFIX)
WG_MTU=$(require WG_MTU)

[ "$(id -u)" = 0 ] || die "must run as root"
[ -r "$SRC_CONF" ] || die "$SRC_CONF is missing — run 'bin/onionvpn init' on the host first"

# A container without NET_ADMIN fails several steps below in confusing ways;
# fail here instead, with the fix in the message.
ip link add onion-probe type dummy >/dev/null 2>&1 \
    || die "no NET_ADMIN capability (compose needs 'cap_add: [NET_ADMIN]')"
ip link del onion-probe

# 1. Render the Tor config and the ruleset from their templates.
mkdir -p /run/onionvpn
for name in torrc onionvpn.nft; do
    sed "s|@WG_SERVER_IP@|$WG_SERVER_IP|g" "$TEMPLATES/$name.template" > "/run/onionvpn/$name"
    # An unsubstituted placeholder would reach Tor or nft as a literal and fail
    # with a confusing parse error, so catch it here by name. Test the captured
    # string, not the pipeline's status: `head` succeeds on empty input, so
    # `if left=$(grep ... | head -n1)` is always true.
    left=$(grep -o '@[A-Z_]*@' "/run/onionvpn/$name" | head -n1 || true)
    [ -z "$left" ] || die "$name.template has an unsubstituted placeholder: $left"
done
log "rendered torrc and ruleset for $WG_SERVER_IP"

# 2. WireGuard interface.
#    wg-quick is deliberately not used for the interface itself: its default route
#    and fwmark handling is pointless for a server that routes nothing, and its
#    sysctl writes fail in some container configurations. Only its `strip` helper
#    is used, to drop the [Interface] keys that wg(8) rejects.
install -m 600 "$SRC_CONF" /etc/wireguard/wg0.conf
ip link show "$WG_IF" >/dev/null 2>&1 || ip link add "$WG_IF" type wireguard
wg-quick strip "$WG_IF" > /run/wg0.stripped
wg setconf "$WG_IF" /run/wg0.stripped
rm -f /run/wg0.stripped
ip addr replace "$WG_SERVER_IP/$WG_PREFIX" dev "$WG_IF"
ip link set mtu "$WG_MTU" up dev "$WG_IF"
log "$WG_IF up: $WG_SERVER_IP/$WG_PREFIX mtu $WG_MTU, udp/$(wg show $WG_IF listen-port), $(wg show $WG_IF peers | grep -c . || true) peer(s)"

# 3. Packet policy. This runs in the container's own network namespace, so it is
#    invisible to the host firewall and to Docker's own tables.
nft -f /run/onionvpn/onionvpn.nft
log "nftables policy loaded (tcp -> tor, dns -> tor, everything else dropped)"

# 4. Routing off, as a second leak guard behind the nftables forward chain.
sysctl -qw net.ipv4.ip_forward=0 2>/dev/null || true

# 5. Onion routing daemon. No browser, no GUI: it builds circuits and serves them
#    on the transparent, DNS and SOCKS ports.
install -d -o tor -g tor -m 750 /run/tor /var/lib/tor
log "starting tor $(tor --version | head -1 | sed 's/^Tor version //') — bootstrap takes 10-60s"
exec su-exec tor:tor tor -f /run/onionvpn/torrc
