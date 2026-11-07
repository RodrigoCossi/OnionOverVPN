#!/bin/sh
# Ask Tor for fresh circuits (the NEWNYM signal), so that connections made from
# now on leave the network through a different exit relay.
#
# Existing connections are not moved — Tor never breaks a live stream — so the
# change shows up on the next new connection, not the current one.
#
# Authentication is Tor's control cookie, which lives in the data directory and
# is readable here because this runs as root inside the container.
set -eu

COOKIE=/var/lib/tor/control_auth_cookie
[ -r "$COOKIE" ] || { echo "control cookie not readable — is Tor running?" >&2; exit 1; }

# The control protocol wants the cookie as a hex string.
hex=$(od -An -tx1 < "$COOKIE" | tr -d ' \n')

reply=$(printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$hex" \
        | socat -T5 - TCP:127.0.0.1:9051 2>/dev/null | tr -d '\r')

if printf '%s' "$reply" | grep -q '^250'; then
    echo "new circuits requested; the next connection will use a different exit relay"
else
    echo "control port refused the request:" >&2
    printf '%s\n' "$reply" >&2
    exit 1
fi
