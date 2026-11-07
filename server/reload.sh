#!/bin/sh
# Re-read /config/wg0.conf and apply it with `wg syncconf`, which adds or
# removes peers without touching the interface. Existing clients keep their
# sessions; nothing reconnects. Called by `bin/onionvpn add|remove` on the host.
set -eu
install -m 600 /config/wg0.conf /etc/wireguard/wg0.conf
wg-quick strip wg0 > /run/wg0.stripped
wg syncconf wg0 /run/wg0.stripped
rm -f /run/wg0.stripped
echo "peers now configured: $(wg show wg0 peers | grep -c . || true)"
