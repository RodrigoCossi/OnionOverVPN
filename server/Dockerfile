# OnionOverVPN server: WireGuard endpoint + Tor onion-routing daemon.
#
# The WireGuard data plane is the host kernel's wireguard module, driven from
# this container's network namespace; only the control tools live in the image.
FROM alpine:3.22

RUN apk add --no-cache \
        wireguard-tools \
        nftables \
        tor \
        iproute2 \
        su-exec \
        socat \
    && rm -rf /var/cache/apk/*

# Templates, not finished configs: entrypoint.sh renders them into /run with the
# addresses from the environment, so no address is baked into the image.
COPY torrc.template        /etc/onionvpn/torrc.template
COPY onionvpn.nft.template /etc/onionvpn/onionvpn.nft.template
COPY entrypoint.sh  /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY reload.sh      /usr/local/bin/reload.sh
COPY newnym.sh      /usr/local/bin/newnym.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
              /usr/local/bin/reload.sh /usr/local/bin/newnym.sh

EXPOSE 51820/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
