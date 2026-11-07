# OnionOverVPN — project notes

WireGuard server + client as two Docker containers; client TCP and DNS are
transparently onion-routed by a Tor daemon in the server container. Built
2026-11-07. User-facing docs: `README.md`. Control everything with `bin/onionvpn`
(run `bin/onionvpn help`).

**No Tor Browser is involved, ever.** The user asked for the onion protocol
only. `tor` here is the routing daemon: TransPort (transparent), DNSPort and
SocksPort, all bound to `10.66.66.1`.

## Live state on this machine

- `onionvpn-server` and `onionvpn-client` containers, compose project `onionvpn`,
  network `onionvpn` pinned to `172.31.66.0/24` (avoids the lab's 172.17-21 etc.).
- Published: `0.0.0.0:51820/udp` (WireGuard) and `127.0.0.1:1080` (SOCKS5 into Tor).
- Tunnel `10.66.66.0/24`; server `.1`, client `docker` `.2`, client `laptop` `.3`.
- `restart: unless-stopped`, so both come back after a reboot. No systemd units.
- Host `tor` package was installed early in the build and is **not used** by the
  containers; it is left only for host-side `torsocks`. Removable.
- The host firewall was never touched. Docker owns `table ip nat` / `table ip
  filter` via iptables-nft; all project rules live inside the containers'
  own netns.

## Things that will bite you

- **nftables requires `comment` to be the last token of a rule**, after the
  verdict: `counter accept comment "x"`, never `counter comment "x" accept`.
  The latter is a syntax error. Cost one build cycle.
- **Don't let the catch-all TCP redirect swallow the gateway's own ports.**
  `server/onionvpn.nft` returns early for `ip daddr 10.66.66.1`, otherwise
  connections to Tor's SocksPort (9050) get redirected to TransPort (9040) and
  SOCKS/`.onion` silently fails while everything else looks fine.
- **The client kill-switch needs `ct state established,related accept` in its
  output chain**, or the SOCKS5 relay accepts connections and cannot answer
  them — it looks exactly like a dead proxy.
- **`wg setconf` resolves a hostname Endpoint itself.** The kill-switch loads
  before the tunnel and blocks Docker's resolver, so `client/entrypoint.sh`
  rewrites the Endpoint to the already-resolved IP before calling `wg setconf`.
  Remove that `sed` and any DNS-name endpoint stops connecting.
- **Rebuild the image you changed.** `docker compose up -d --build server` does
  not rebuild the client. Two debugging rounds were spent on a stale client image.
- `wg-quick` is deliberately not used to bring interfaces up: its fwmark and
  sysctl handling is unnecessary here and fails in containers. Only
  `wg-quick strip` is used. The client does routing explicitly in three lines.
- Tor's notices log is on **tmpfs** (`/run`) on purpose: on the writable layer a
  `docker restart` would leave a stale `Bootstrapped 100%` for the healthcheck.
- ICMP from a client is dropped by `net.ipv4.ip_forward=0` *before* the nftables
  forward hook, so the `DROPPED no clearnet route` counter stays at 0 even
  though the drop is working. Don't read that zero as a broken rule.

## This repo is meant to go public — keep it publishable

Intended as a **public GitHub repo** (user, 2026-11-07). Nothing in this repo may contain a
public IP address, a hostname, a provider name or an account identifier. Use the RFC 5737
documentation ranges (`203.0.113.0/24`, `198.51.100.0/24`) in examples. `.gitignore` already
excludes `.env`, `config/` and `clients/` — those hold the keys and the generated client
configs, which legitimately carry the server's real address and so are never committed.

**This deployment's actual values** — public address, the provider firewall's source
allowlist, which clients were issued — are kept in the machine's private memory store, not
here. Look them up there before debugging a connection; do not copy them back into this repo.

## Provider firewall filtering by source address

Where the provider's firewall allows UDP only from certain sources, only a client whose
**public egress address** is in that set can handshake, however correct its config.
`onionvpn list` has a `SEEN COMING FROM` column showing the source the server actually
received packets from — the value such a rule matches on. `never` + `-` means no packet
arrived at all, which is the signature of a source-filter drop rather than a config error.

Measured caveat on that column: when the sender is on this same host (another container, or
the host reaching its own public address), Docker's `ip saddr 172.x … masquerade` rules
rewrite the source and the column shows the bridge gateway (`172.31.66.1`). A genuine
external source matches no masquerade rule, so its real address is preserved — read off the
ruleset, **not** measured, because a single host cannot generate traffic from a foreign address.

Consequences to raise before anyone tries: a **phone on mobile data will not connect** if the
allowlist holds fixed addresses, and a rotating residential address silently breaks the tunnel
until the rule is updated.

## Verified 2026-11-07

`bin/onionvpn test` — 9/9 pass from inside the client namespace: handshake,
default route via wg0, DNS inside the tunnel, `IsTor:true` from
check.torproject.org, exit address differs from the host's own public address, ICMP
dropped, no clear-net default route, `.onion` reachable over SOCKS5 (HTTP 301).

Kill-switch measured directly, not assumed: `curl --interface eth0` and a
`wg0 down` + `curl` both failed, with 6 packets on the
`DROPPED would have bypassed the tunnel` counter.

`docker-compose.client.yml` (the standalone client, the file a user copies to their own
machine) was run for real, not just written: with `CLIENT_CONF` and `SOCKS_PORT=1081` it
handshaked over the public address and passed 9/9, and the host SOCKS port honoured the override.
Every CLI command has now been exercised at least once, including `restart`, `show`, `qr`, `logs`
and `uninstall`'s cancel path.

The **published-port path** was verified too, not just the container-to-container one:
a throwaway client built from the `laptop` config (whose endpoint is the host's public
address, not the container name) on a different Docker network handshaked and passed
9/9 through the published port. So
Docker's `dnat to 172.31.66.2:51820` publish path carries a full working tunnel. Two
clients were up at once during that test with no interference.

Circuit rotation measured: `onionvpn exit-ip` reported one exit relay, `newnym`, then a
different one. Survives `docker compose down` + `onionvpn up`.

**Not verified, and cannot be from this host:**
- **IPv6 leak protection.** The client container has no global IPv6 address, so `curl -6` fails
  there for the wrong reason and `onionvpn test` says nothing about it. The design is sound
  (`::/0` in `AllowedIPs`, no IPv6 on `wg0`, inet drop policy) but it is *untested*. It must be
  checked on a real dual-stack client; the README tells the user how.
- **Reboot persistence.** `restart: unless-stopped` is standard Docker behaviour but was not
  tested by rebooting — the user reaches this box over RDP, and restarting the Docker daemon would
  bounce their other containers. What *was* tested: a crash of Tor (`docker exec ... kill 1`)
  brought the container back by itself, `RestartCount` 1, healthy, Tor re-bootstrapped in seconds.
  Note `docker kill` does **not** trigger a restart — Docker treats it as a manual stop, so don't
  read that as a broken policy.
- **Throughput and latency.** Never benchmarked. Expect a few Mbit/s and 300ms+; three relays.
- **`onionvpn uninstall`'s destructive branch.** Only the cancel path was exercised, deliberately:
  the machine rule is not to remove Docker images the lab may need. The cancel path works.

Re-verified 9/9 after the templating refactor, and the refactor itself was proved by
rendering the server templates with a different `WG_SERVER_IP`: all three Tor listeners
and the nftables gateway rule followed it, with zero leftover placeholders and no trace
of the previous subnet.

## Design decisions worth not re-litigating

- **Containers over host install**: the server's "redirect everything into Tor"
  policy and the client's "nothing but the tunnel leaves" policy are opposites
  and must not share a namespace. Containers give that for free and keep both
  away from the host's Docker-managed tables.
- **Co-located client uses `onionvpn-server:51820`** as its endpoint, not the
  public IP, so `onionvpn test` keeps working if the host's address changes.
  Real devices get the public IP from `.env`.
- **The client container does not seize the host's default route.** It offers
  SOCKS5 and sidecar mode; whole-device tunnelling is the normal WireGuard app's
  job with the same `.conf`.
- Onion routing is TCP-only. UDP/QUIC/ICMP are dropped, never passed through in
  the clear. This is the leak protection and has no exceptions.
