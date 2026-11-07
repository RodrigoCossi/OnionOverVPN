# OnionOverVPN

WireGuard in front of onion routing, as two Docker containers.

```
your device ──[ WireGuard, UDP ]──▶ server container ──[ Tor circuits ]──▶ internet
   client                            wg0 10.66.66.1                        exit relay
```

Your ISP sees one encrypted UDP flow to one address and cannot tell that Tor is
involved. The websites you reach see a Tor exit relay. Nobody in between sees
both ends.

This is the onion-routing **daemon** only — no Tor Browser, no GUI, nothing to
launch. `tor` here is a network daemon that builds circuits and exposes them as
a transparent proxy, a DNS resolver and a SOCKS5 port.

## Quick start

On the server host:

```sh
bin/onionvpn init          # keys, configs, detects the public IP
bin/onionvpn up            # builds the images and starts both containers
bin/onionvpn test          # end-to-end verification
bin/onionvpn exit-ip       # the address the internet currently sees
```

Add a device:

```sh
bin/onionvpn add phone     # writes clients/phone/phone.conf and a QR code
bin/onionvpn qr phone      # scan it with the WireGuard app
```

**UDP 51820** must be reachable from the internet. It is the only port that needs
to be, and the host's own firewall is not touched by this project — see the next
section if your provider filters by source address.

## Connecting from outside

WireGuard's handshake arrives at the server from the client's **public source
address**. If your provider's firewall allows UDP only from certain sources — some
VPS panels default to that — then only a machine whose traffic egresses from one of
those addresses can connect, no matter how the client is configured.

`onionvpn list` shows what the server actually received, which is the value such a
rule matches on:

```
NAME           ADDRESS      LAST HANDSHAKE  SEEN COMING FROM
docker         10.66.66.2   55s ago         172.31.66.3:35994
laptop         10.66.66.3   never           -
```

Reading it:

* **`never` and `-`** — no packet from that client ever arrived. Either it has not
  been started, or the firewall dropped it. Run `curl -4 ifconfig.me` on the client
  machine and compare the result with your firewall's allowed sources.
* **an address you recognise** — packets are arriving and the firewall is letting
  them through.
* **`172.31.66.1`** — the source was rewritten, because the traffic came from this
  same host (another container, or the host itself reaching its own public IP).
  Docker masquerades that; genuine external traffic is not masqueraded and shows
  its real address.

Two consequences of a source allowlist worth planning around:

* **A phone on mobile data will not connect**, because its carrier address is not
  on the list. The QR codes are only useful on a network you have allowed.
* **Residential addresses rotate.** When your ISP changes yours, the tunnel stops
  handshaking with no error on the client beyond a stalled connection — the
  `never` / `-` row above is the symptom. Update the firewall rule, or ask the
  provider for a rule you can edit quickly.

## Running the client on your own machine

This is the normal split: server on the remote host, client on your laptop.

```sh
# on the server
bin/onionvpn add laptop

# copy to your machine: docker-compose.client.yml, the client/ directory,
# and clients/laptop/laptop.conf
CLIENT_CONF=./laptop.conf docker compose -f docker-compose.client.yml up -d --build
docker exec onionvpn-client /usr/local/bin/verify.sh
```

You then have two ways to use it, and they are not equivalent:

| | What it covers | How |
|---|---|---|
| **SOCKS5 proxy** | one app at a time | point it at `127.0.0.1:1080` |
| **WireGuard app** | the whole device | import the same `.conf` |
| **Sidecar** | one container | `network_mode: "service:client"` |

Prefer SOCKS5 where the app supports it. A SOCKS5-aware client hands Tor a
hostname instead of resolving it first, so there is no DNS step that could leak
at all. The client container deliberately does **not** take over your machine's
routing: a container cannot do that safely. Import the `.conf` into the ordinary
WireGuard app when you want the whole device tunnelled.

## The IP you will see

A Tor exit relay's — never the VPN server's. That is the whole point: with a
plain VPN every site sees your server's address, which is one stable identifier
pointing at a machine rented in your name.

It is also not stable, by design:

* it changes on its own roughly every 10 minutes,
* it differs per destination, because Tor uses separate circuits,
* `bin/onionvpn newnym` changes it immediately.

Sites that pin a session to an IP will log you out when it rotates. That is Tor
working, not a fault.

## What does not work, and why

Onion routing carries **TCP only**. There is no way to put UDP or ICMP through a
Tor circuit, so this setup drops them rather than quietly sending them over the
clear internet instead. In practice:

* **ping / traceroute** — dead.
* **QUIC / HTTP3** — dropped. Browsers retry over TCP after a timeout, so pages
  feel slow to start. Turn QUIC off in the browser and that goes away.
* **Video and voice calls, most online games** — will not work at all.
* **Speed** — expect a few Mbit/s and 300ms+ of latency. Three relays, often on
  different continents.
* **CAPTCHAs and blocks** — many sites treat Tor exits as hostile. Expect them.

If any of that is a surprise, it is worth re-reading before you depend on this.

## What this protects, and what it does not

**It does protect** against your ISP or local network knowing you use Tor, and
against the sites you visit learning anything about your address. Combined, that
is the reason to run it.

**It does not make you anonymous.** Three things worth being honest about:

1. **You own the server.** It sees your traffic before Tor does, and it is
   rented in your name with your payment details. Against an adversary who can
   reach your provider, this arrangement gives up more than it hides. What it
   hides is your *ISP's* view, which is a real and different threat.
2. **A normal browser identifies you anyway.** Fingerprinting, cookies and logins
   work exactly as before. Tor Browser exists because of that, not because of
   routing. If web anonymity is the goal, use Tor Browser — this setup is for
   torifying whole devices that cannot run it, such as a phone, a TV or an IoT
   box, and for keeping Tor use off your ISP's records.
3. **WireGuard is easy to fingerprint.** A network that wants to block VPNs can
   recognise it. If "my ISP must not know I use a VPN *either*" is a requirement,
   this is the wrong tool — an obfs4 or Snowflake Tor bridge hides Tor from the
   ISP with no server to rent, and without one operator seeing all your traffic.

## Commands

```
onionvpn init            generate server keys and configs (run once)
onionvpn up              build if needed, then start the stack
onionvpn down            stop the stack
onionvpn restart         restart both containers
onionvpn status          tunnel, peers, Tor bootstrap, drop counters
onionvpn test            full end-to-end verification through the tunnel
onionvpn exit-ip         the address the internet currently sees
onionvpn newnym          force new circuits, i.e. a different exit address
onionvpn add <name>      add a client, write its .conf and QR code
onionvpn remove <name>   revoke a client
onionvpn list            list clients
onionvpn show <name>     print a client config
onionvpn qr <name>       print a client config as a QR code
onionvpn logs [svc]      follow container logs
onionvpn uninstall       remove containers, images and the Tor cache
```

## Check this yourself on a dual-stack machine

One protection cannot be exercised in a container: **IPv6**. The generated configs put `::/0` in
`AllowedIPs` so IPv6 is pulled into the tunnel, where `wg0` has no IPv6 address and the server's
drop policy applies. That is the design — but a Docker container typically has no global IPv6
address, so `onionvpn test` passing there proves nothing about it.

Your laptop or phone probably does have IPv6, and an escaping IPv6 route is the classic
full-tunnel leak. With the tunnel up, confirm both of these:

```sh
curl -6 -s --max-time 8 https://ipv6.google.com/   # must fail
```

and open `https://test-ipv6.com` — it should find no working IPv6 address. If it finds one, your
IPv6 traffic is bypassing the tunnel and is not onion-routed.

## Configuration lives in one file

No address is hardcoded in the scripts, the Tor config or the nftables rulesets.
`torrc.template`, `onionvpn.nft.template` and `killswitch.nft.template` are
templates; the entrypoints render them at container start from `.env` (via
Compose) and from the client config, and refuse to start if a placeholder is left
unsubstituted or a required value is missing. `bin/onionvpn init` builds `.env` by
copying `.env.example` and filling in the detected public address, so every
default has exactly one home.

Change the tunnel subnet and everything follows — Tor's three listeners, the
redirect rules, the generated client configs. (Re-issue clients afterwards with
`onionvpn add`: their address and DNS server are baked into the config they hold.)

The only addresses written literally anywhere are these, all deliberate:

| Literal | Where | Why it is not configuration |
|---|---|---|
| `127.0.0.1` | Tor's control port, `newnym.sh`, the SOCKS publish | Loopback. Binding Tor's control port anywhere else would hand control of the daemon to the network |
| `0.0.0.0/0`, `::/0` | generated client configs | WireGuard's "everything" wildcards, not addresses |
| `10.192.0.0/10` | `torrc.template` | Tor's own documented default for `.onion` virtual addresses. Must not overlap the tunnel subnet |
| `203.0.113.x`, `198.51.100.x` | docs and `.env.example` | RFC 5737 documentation ranges — placeholders, never real hosts |

## How it is put together

| File | Role |
|---|---|
| `server/onionvpn.nft` | redirects client TCP into Tor, DNS into Tor's resolver, drops the rest |
| `server/torrc` | the onion-routing daemon; every listener bound to `10.66.66.1` |
| `server/entrypoint.sh` | tunnel up, policy loaded, then Tor — in that order |
| `client/killswitch.nft` | only the encrypted tunnel may leave over the real interface |
| `client/entrypoint.sh` | explicit three-route setup instead of `wg-quick` |
| `client/verify.sh` | the end-to-end checks `onionvpn test` runs |
| `bin/onionvpn` | all host-side control; keys never leave `config/` |

Four things stop traffic escaping to the clear internet, independently:

1. the server's nftables `forward` chain drops everything,
2. `net.ipv4.ip_forward=0` in the server container,
3. Tor's DNSPort is the only resolver a client is given,
4. the client's kill-switch allows nothing but the tunnel out of its real
   interface, so a dropped tunnel means no traffic at all rather than traffic in
   the clear.

Both containers run with `NET_ADMIN` in their own network namespaces. Neither
can affect the host's firewall, and the two rulesets are deliberately in
separate namespaces because they are opposites.

Private keys live in `config/` and `clients/`, both mode 700. `onionvpn remove`
moves a revoked client's keys to `clients/.revoked/` rather than deleting them,
so a mistake is recoverable; delete that directory to make a revocation final.
