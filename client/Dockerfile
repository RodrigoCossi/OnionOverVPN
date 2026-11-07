# OnionOverVPN client: a WireGuard gateway container.
#
# Two ways to use it:
#   1. Put other containers behind it with `network_mode: "service:client"` —
#      they then reach the internet only through WireGuard, then Tor.
#   2. Use the SOCKS5 port it re-exposes from the server's Tor daemon, so apps
#      on the host (a browser, curl, any SOCKS-aware tool) can use the path
#      without changing the host's routing at all.
FROM alpine:3.22

RUN apk add --no-cache \
        wireguard-tools \
        nftables \
        iproute2 \
        socat \
        curl \
        ca-certificates \
    && rm -rf /var/cache/apk/*

# A template, not a finished ruleset: entrypoint.sh fills in the endpoint and the
# ports from the environment, so no address is baked into the image.
COPY killswitch.nft.template /etc/onionvpn/killswitch.nft.template
COPY entrypoint.sh   /usr/local/bin/entrypoint.sh
COPY verify.sh       /usr/local/bin/verify.sh
COPY healthcheck.sh  /usr/local/bin/healthcheck.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/verify.sh \
              /usr/local/bin/healthcheck.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
