#!/bin/sh
# OnionOverVPN client entrypoint.
#
# Builds the tunnel by hand rather than with wg-quick. wg-quick would route
# 0.0.0.0/0 using a firewall mark, which needs sysctls a container often cannot
# write; the explicit version below does the same job in three routes and is
# much easier to reason about:
#
#   <endpoint>/32  via the original gateway   <- the encrypted tunnel itself
#   default        dev wg0                    <- everything else
#   (kill-switch)                             <- and nothing may bypass that
set -eu

log() { printf '[onionvpn-client] %s\n' "$*"; }
die() { printf '[onionvpn-client] ERROR: %s\n' "$*" >&2; exit 1; }

CONF=/config/client.conf
MODE=${MODE:-gateway}
WG_IF=wg0

require() {
    eval "value=\${$1:-}"
    [ -n "$value" ] || die "$1 is not set — compose passes it from .env; run 'bin/onionvpn init'"
    printf '%s' "$value"
}

# No address or port is hardcoded in this project: every value comes from .env via
# compose, or from the client config itself. A missing one is an error rather than
# a default, because a default that disagrees with the server is worse than a stop.
SOCKS_PORT=$(require SOCKS_PORT)
DOCKER_DNS=$(require DOCKER_EMBEDDED_DNS)

[ "$(id -u)" = 0 ] || die "must run as root"
[ -r "$CONF" ] || die "$CONF is missing — run 'bin/onionvpn init' on the host first"
ip link add onion-probe type dummy >/dev/null 2>&1 \
    || die "no NET_ADMIN capability (compose needs 'cap_add: [NET_ADMIN]')"
ip link del onion-probe

# Read one key out of the WireGuard config. Case-insensitive, trims whitespace
# and any CRs from a config that travelled through Windows.
conf_get() {
    grep -i "^[[:space:]]*$1[[:space:]]*=" "$CONF" 2>/dev/null \
        | head -n1 | cut -d= -f2- \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r'
}

ADDR=$(conf_get Address)
DNS=$(conf_get DNS)
MTU=$(conf_get MTU); MTU=${MTU:-1420}
ENDPOINT=$(conf_get Endpoint)
[ -n "$ADDR" ]     || die "no Address in $CONF"
[ -n "$ENDPOINT" ] || die "no Endpoint in $CONF"
[ -n "$DNS" ]      || die "no DNS in $CONF — without it lookups would leak"

EP_HOST=${ENDPOINT%:*}
EP_PORT=${ENDPOINT##*:}

# Resolve the endpoint now, while normal DNS still works: once the kill-switch
# is loaded, a name lookup outside the tunnel is no longer possible.
case "$EP_HOST" in
    *[a-zA-Z]*) EP_IP=$(getent ahostsv4 "$EP_HOST" | awk 'NR==1{print $1}') ;;
    *)          EP_IP=$EP_HOST ;;
esac
[ -n "$EP_IP" ] || die "cannot resolve endpoint host '$EP_HOST'"

ORIG_GW=$(ip -4 route show default | awk '{print $3; exit}')
ORIG_DEV=$(ip -4 route show default | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
[ -n "$ORIG_GW" ] || die "no default route to reach the endpoint through"
log "endpoint $EP_HOST:$EP_PORT -> $EP_IP, reachable via $ORIG_GW dev $ORIG_DEV"

# 1. Kill-switch first, before the tunnel exists. Loading it afterwards would
#    leave a brief window in which wg0 is up and unprotected, and the endpoint
#    is already resolved above, so nothing here needs the network.
sed -e "s|@ENDPOINT_IP@|$EP_IP|g" \
    -e "s|@ENDPOINT_PORT@|$EP_PORT|g" \
    -e "s|@SOCKS_PORT@|$SOCKS_PORT|g" \
    -e "s|@DOCKER_DNS@|$DOCKER_DNS|g" \
    /etc/onionvpn/killswitch.nft.template > /run/killswitch.nft
# An unsubstituted placeholder would reach nft as a literal and fail with a
# confusing parse error, so catch it here by name. Test the captured string, not
# the pipeline's status: `head` succeeds on empty input.
left=$(grep -o '@[A-Z_]*@' /run/killswitch.nft | head -n1 || true)
[ -z "$left" ] || die "killswitch.nft.template has an unsubstituted placeholder: $left"
nft -f /run/killswitch.nft
rm -f /run/killswitch.nft
log "kill-switch loaded: nothing but the tunnel may leave over $ORIG_DEV"

# 2. Tunnel.
install -m 600 "$CONF" /etc/wireguard/wg0.conf
ip link show "$WG_IF" >/dev/null 2>&1 || ip link add "$WG_IF" type wireguard
wg-quick strip "$WG_IF" > /run/wg0.stripped
# Pin the endpoint to the address resolved above. wg(8) resolves a hostname
# endpoint itself, and the kill-switch has already blocked the resolver it would
# use — so without this line a config with a DNS name never connects. Resolving
# once, here, also means the route and the tunnel can never disagree about
# which address the endpoint is.
sed -i "s|^[[:space:]]*[Ee][Nn][Dd][Pp][Oo][Ii][Nn][Tt][[:space:]]*=.*|Endpoint = $EP_IP:$EP_PORT|" \
    /run/wg0.stripped
wg setconf "$WG_IF" /run/wg0.stripped
rm -f /run/wg0.stripped
ip addr replace "$ADDR" dev "$WG_IF"
ip link set mtu "$MTU" up dev "$WG_IF"

# 3. Routing: pin the endpoint to the old path, then send everything else into
#    the tunnel. Order matters — the default route must not swallow the
#    endpoint itself, or the tunnel would have to carry its own packets.
ip route replace "$EP_IP/32" via "$ORIG_GW" dev "$ORIG_DEV"
ip route replace default dev "$WG_IF"
log "default route now via $WG_IF ($ADDR)"

# 4. DNS. Docker's embedded resolver (DOCKER_EMBEDDED_DNS) would answer from the
#    HOST's resolver, which is exactly the leak this whole setup exists to
#    prevent, so it is replaced here and the kill-switch above blocks it outright.
printf '# set by OnionOverVPN: resolved inside Tor\nnameserver %s\noptions timeout:5 attempts:2\n' "$DNS" \
    > /etc/resolv.conf 2>/dev/null \
    || die "cannot write /etc/resolv.conf (is the container read_only?)"
grep -q "^nameserver $DNS\$" /etc/resolv.conf \
    || die "/etc/resolv.conf did not take the change — refusing to run with leaky DNS"
log "DNS set to $DNS (Tor's DNSPort, reached over the tunnel)"

if [ "$MODE" = "verify" ]; then
    exec /usr/local/bin/verify.sh
fi

# 5. Re-expose the server's Tor SOCKS5 port. This is the preferred way to use
#    the path from the host: a SOCKS5-aware app hands Tor a hostname instead of
#    resolving it first, so there is no DNS step to leak at all.
log "SOCKS5 relay listening on :$SOCKS_PORT -> ${DNS}:9050 (Tor, over the tunnel)"
socat TCP-LISTEN:"$SOCKS_PORT",fork,reuseaddr TCP:"$DNS":9050 &
SOCAT_PID=$!

shutdown() { log "stopping"; kill "$SOCAT_PID" 2>/dev/null || true; exit 0; }
trap shutdown TERM INT

log "ready"
wait "$SOCAT_PID"
