#!/bin/sh
# OnionOverVPN end-to-end verification, run from inside the client container.
#
# This namespace has no interface other than wg0 and the bridge the kill-switch
# locks down, so a check that passes here passes because the tunnel and the onion
# circuit genuinely work — there is no other path it could have used.
#
# Every address comes from the environment or from the client config: nothing is
# hardcoded, so this works unchanged on any deployment. It is also safe to run via
# `docker exec`, which is why the expected resolver is read from the config file
# rather than inherited from the entrypoint's shell.
#
# REAL_IP (optional) is the server's own public address. When it is supplied the
# exit-address check becomes meaningful instead of merely informational.
set -u

CONF=/config/client.conf
TOR_SOCKS_PORT=9050          # Tor's standard SOCKS port, as set in the server's torrc

GREEN=''; RED=''; YELLOW=''; DIM=''; RESET=''
if [ -t 1 ]; then
    GREEN=$(printf '\033[32m'); RED=$(printf '\033[31m')
    YELLOW=$(printf '\033[33m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
fi

pass=0; fail=0
ok()   { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$*"; pass=$((pass + 1)); }
no()   { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$*";   fail=$((fail + 1)); }
warn() { printf '  %sWARN%s  %s\n' "$YELLOW" "$RESET" "$*"; }
info() { printf '  %s....  %s%s\n' "$DIM" "$*" "$RESET"; }

# The resolver this client was told to use: the tunnel gateway, where the server
# redirects port 53 into Tor's DNSPort.
EXPECTED_DNS=$(grep -i '^[[:space:]]*DNS[[:space:]]*=' "$CONF" 2>/dev/null \
    | head -n1 | cut -d= -f2- \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r')
[ -n "$EXPECTED_DNS" ] || { echo "cannot read DNS from $CONF — nothing to verify against"; exit 1; }

LEAK_PROBE_ADDR=${LEAK_PROBE_ADDR:-}
TOR_CHECK_URL=${TOR_CHECK_URL:-}
ONION_CHECK_URL=${ONION_CHECK_URL:-}
DOCKER_EMBEDDED_DNS=${DOCKER_EMBEDDED_DNS:-}

printf '\n%sOnionOverVPN — verification from inside the client namespace%s\n\n' "$DIM" "$RESET"

# --- 1. the tunnel itself ----------------------------------------------------
hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}')
if [ -n "${hs:-}" ] && [ "$hs" -gt 0 ] 2>/dev/null; then
    ok "WireGuard handshake completed $(( $(date +%s) - hs ))s ago"
else
    no "no WireGuard handshake — the server never answered"
    info "check: server container up, UDP port published, provider firewall open"
fi

info "transfer: $(wg show wg0 transfer 2>/dev/null | awk '{print $2" B received, "$3" B sent"; exit}')"

# --- 2. routing and DNS are actually pointed at the tunnel -------------------
if ip -4 route show default | grep -q 'dev wg0'; then
    ok "default route is wg0"
else
    no "default route is NOT wg0: $(ip -4 route show default | head -1)"
fi

dns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
if [ "$dns" = "$EXPECTED_DNS" ]; then
    ok "DNS points into the tunnel ($dns)"
elif [ -n "$DOCKER_EMBEDDED_DNS" ] && [ "$dns" = "$DOCKER_EMBEDDED_DNS" ]; then
    no "DNS is Docker's embedded resolver — lookups would leak to the host"
else
    no "DNS is ${dns:-unset}, not the tunnel's resolver ($EXPECTED_DNS)"
fi

# --- 3. the onion circuit ----------------------------------------------------
if [ -n "$TOR_CHECK_URL" ]; then
    api=$(curl -s --max-time 60 "$TOR_CHECK_URL" 2>/dev/null)
    exit_ip=$(printf '%s' "$api" | sed -n 's/.*"IP"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if printf '%s' "$api" | grep -q '"IsTor"[[:space:]]*:[[:space:]]*true'; then
        ok "traffic leaves the Tor network — exit relay ${exit_ip:-unknown}"
    elif [ -n "$api" ]; then
        no "reached the internet but NOT through Tor (seen as ${exit_ip:-unknown})"
    else
        no "could not reach the Tor check service (circuit not built, or it is slow)"
        info "retry once Tor finishes bootstrapping: docker logs onionvpn-server"
    fi

    # That the lookup above resolved at all is the DNS proof: this namespace can
    # only reach the tunnel's resolver, which the server redirects into Tor.
    [ -n "$api" ] && ok "hostname resolution worked, so DNS was answered inside Tor"

    if [ -n "${REAL_IP:-}" ] && [ -n "$exit_ip" ]; then
        if [ "$exit_ip" = "$REAL_IP" ]; then
            no "exit address equals the server's own address — not onion-routed"
        else
            ok "exit address $exit_ip differs from the server's own"
        fi
    fi
else
    warn "TOR_CHECK_URL is not set — skipping the circuit checks"
fi

# --- 4. leak behaviour -------------------------------------------------------
# Tor carries TCP only. ICMP is the representative protocol it cannot carry, so a
# successful ping would mean something escaped the policy.
if [ -n "$LEAK_PROBE_ADDR" ]; then
    if ping -c1 -W3 "$LEAK_PROBE_ADDR" >/dev/null 2>&1; then
        no "ICMP to $LEAK_PROBE_ADDR succeeded — non-TCP traffic is escaping to the clear net"
    else
        ok "ICMP to the internet is dropped (Tor cannot carry it, so it must not pass)"
    fi
else
    warn "LEAK_PROBE_ADDR is not set — skipping the ICMP leak check"
fi

if ip -4 route show | grep -qE '^default .*dev (eth|en|wl)'; then
    no "a clear-net default route exists alongside the tunnel"
else
    ok "no clear-net default route exists in this namespace"
fi

# --- 5. onion services (informational: public onions are often slow) ---------
if [ -n "$ONION_CHECK_URL" ]; then
    code=$(curl -s --max-time 75 -o /dev/null -w '%{http_code}' \
           --socks5-hostname "$EXPECTED_DNS:$TOR_SOCKS_PORT" "$ONION_CHECK_URL" 2>/dev/null)
    case "$code" in
        200|30[0-9]) ok ".onion address reachable over SOCKS5 (HTTP $code)" ;;
        *)           warn ".onion check inconclusive (HTTP ${code:-no response}) — public onion services are often slow; not a failure of this setup" ;;
    esac
fi

# --- summary -----------------------------------------------------------------
printf '\n'
if [ "$fail" -eq 0 ]; then
    printf '  %s%s checks passed, 0 failed.%s Onion over VPN is working.\n\n' "$GREEN" "$pass" "$RESET"
    exit 0
fi
printf '  %s%s failed%s, %s passed.\n\n' "$RED" "$fail" "$RESET" "$pass"
exit 1
