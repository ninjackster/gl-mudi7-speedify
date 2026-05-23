# Speedify on a GL.iNet Mudi 7, with a self-hosted server on a Mac (Colima)

This is a writeup of a setup I could not find documented anywhere when I built
it: running the Speedify client on a **GL.iNet Mudi 7 (GL-E5800)** travel
router, and pointing it at my **own self-hosted Speedify server** running on an
Intel Mac via **Colima**, so my bonded traffic exits with my **home IP** while
still getting Speedify's link bonding.

Two parts here are not in the official docs:

1. The Mudi 7 is **not** on Speedify's supported-device list (the Slate 7
   GL-BE3600 is). It installs and works anyway, with a few gotchas specific to
   this Qualcomm box.
2. Self-hosting the Speedify server in **Colima** (Docker-in-a-VM on macOS) does
   not work out of the box for remote clients. The reason is subtle and the fix
   is non-obvious. As far as I can tell this is the first writeup of the working
   configuration.

If you only want bonding to Speedify's public servers, you can stop after the
client section. The self-hosted part is for people who specifically want their
traffic to egress with their home IP (think WireGuard-to-home, but you keep the
multi-link bonding).

Everything below uses placeholders like `<WAN_IP>`, `<VM_LAN_IP>`,
`<LAN_IFACE>`, `<SSID>`, `<ROUTER_LAN_IP>`. Substitute your own values.

---

## Part 1 -- The Speedify client on the Mudi 7

### Hardware and firmware

- GL.iNet Mudi 7 (GL-E5800), aarch64, OpenWrt 23.05.4, GL firmware 4.8.x.
- Not on Speedify's official supported list. I installed it anyway and it runs
  fine.
- You need a Speedify **Router License** for the client side.

### Install

SSH into the Mudi (`ssh root@<ROUTER_LAN_IP>`) and run the official installer:

```sh
wget -q https://get.speedify.com -O- | sh
```

The CLI lands at `/usr/share/speedify/speedify_cli`. Sign in with a router
license using the activation-code flow (it gives you a URL to open in a
browser):

```sh
speedify_cli activationcode
```

Then connect, check state, etc.:

```sh
speedify_cli state
speedify_cli show servers
speedify_cli connect
```

### Gotcha A -- "Network Acceleration" conflicts with Speedify's PEP

This is the big one on this box.

GL.iNet's **Network Acceleration** toggle, on this Qualcomm Mudi 7, maps to the
OpenWrt `firewall.@defaults[0].flow_offloading` flag. (Speedify's docs talk
about SFE / `qcmap_sfe` hardware offload, but that is not what is configured
here. On this unit it is plain software flow offloading.)

Flow offloading conflicts with Speedify's PEP. With it ON, Speedify reports
**connected but no internet**: the tunnel comes up, no traffic passes. So it has
to be **OFF while Speedify is connected**.

The annoying part: disabling flow offloading tanks routed throughput on a
gigabit line. I measured roughly **400-600 Mbps down to about 130 Mbps** to a
WiFi client with it off. So you do not just want to leave it off forever.

The answer is to keep Network Acceleration **ON normally** and flip it **OFF
only while Speedify is connected**, automatically. This repo includes:

- `na-on` / `na-off` -- manual toggles (set `flow_offloading` and reload the
  firewall).
- `speedify-na-watch` -- a small loop that polls `speedify_cli state` every 10
  seconds and toggles `flow_offloading` to match: OFF when Speedify is
  connected, ON otherwise. It only writes/reloads on an actual state change.
- `speedify-na-watch.init` -- a procd init script so the watcher runs as a
  managed service and survives reboots.

Install on the Mudi:

```sh
# copy the files over, then on the router:
cp na-on na-off /usr/bin/
cp speedify-na-watch /usr/bin/speedify-na-watch
cp speedify-na-watch.init /etc/init.d/speedify-na-watch
chmod +x /usr/bin/na-on /usr/bin/na-off /usr/bin/speedify-na-watch /etc/init.d/speedify-na-watch

/etc/init.d/speedify-na-watch enable
/etc/init.d/speedify-na-watch start

# watch it work:
logread | grep speedify-na
```

Now you get fast routing when you are not tunneling, and a working tunnel when
you are, with no manual flipping.

### Gotcha B -- the WiFi-as-WAN repeater penalty

The Mudi 7 has a single 5GHz radio. If you run a 5GHz access point **and** use
5GHz WiFi-as-WAN (repeater mode) at the same time, the radio gets forced onto
the upstream AP's channel at 40MHz width. That roughly halves your WiFi
throughput. I saw it drop from around **640 Mbps to about 150 Mbps**.

Two ways out:

- Pin a clean 5GHz channel at 80MHz width on the Mudi's AP, or
- Just do not run WiFi-as-WAN while you are on Ethernet (use the wired WAN and
  let the radio be a clean AP).

This is a single-radio physics problem, not a Speedify problem, but it bites
hard if you are repeating hotel/venue WiFi as one of your bonded links.

### Gotcha C -- firmware updates wipe Speedify

A GL firmware update keeps your config (anything in `/etc/config` survives) but
**removes the Speedify binaries**. After any firmware bump you have to reinstall
Speedify (`wget -q https://get.speedify.com -O- | sh`) and re-confirm Network
Acceleration is handled (re-install the watcher files if they were under
`/usr/bin`, since those are not in `/etc/config`).

Also worth knowing: **the Mudi 7 has no U-Boot web recovery** (per GL's debrick
FAQ). There is no browser-based "uh oh" failsafe like some other GL units have.
Keep **off-box backups** of your config so a bad flash does not strand you.

### Throughput notes (test multi-stream, always)

The Speedify **client** on the Mudi caps around **490 Mbps** in a multi-
connection test (Ookla / Speedtest, which opens many parallel streams) to public
Speedify servers.

Do not trust single-stream tests. A router-side `wget` of one big file
undercounts badly, around **220 Mbps** in my testing, because a single TCP
stream does not exercise the bonded paths the way Speedify expects. Always test
with a multi-stream tool or you will think the box is half as fast as it is.

---

## Part 2 -- The self-hosted Speedify server (the novel part)

### Goal

Run your own Speedify server so that bonded traffic from the Mudi exits with
your **home public IP**. It is the home-IP benefit of a WireGuard-to-home setup,
except you keep Speedify's bonding across multiple links.

### What you need

- The Speedify image: `speedify/ss-manager:latest` (`linux/amd64`).
- A **Self-Hosted Personal** license (about $40/mo, 5 devices) on top of the
  client (router) license.
- A host that can run an amd64 container. I used an **Intel Mac** running
  **Colima** (Docker-in-a-VM). Do **not** use Apple Silicon: the only image is
  amd64, and emulating it for a CPU-bound bonding/crypto workload is the worst
  case. Native Intel beats an emulated faster chip here.
- A real, **non-CGNAT public IP** on your home connection. In my case the Mac
  sits behind a GL.iNet Flint 3 on AT&T Fiber with **IP Passthrough**, so the
  router holds the public IP and forwards to the LAN.

### Stand it up

`docker-compose.yml` in this repo is the service. The short version:

```sh
colima start                 # see the bridged-networking section first
docker compose pull
docker compose up -d
docker compose logs -f       # watch for the QR code + activation URL
```

Open the activation URL, sign into Speedify, buy the **Self-Hosted Personal**
license, then apply it by bouncing the stack:

```sh
docker compose down && docker compose up -d
```

### Compose gotchas

**1. Publish ONLY the API port on the parent container.** The parent
`ss-manager` container should publish just the API port (`8443`). It spawns a
**child container** (`speedify/simple-ss`) per client connection, and each child
publishes its own session port within `PUBLISHED_PORT_RANGE`. If you pre-bind
that whole range on the parent (e.g. `51000-51100:51000-51100`), you get
**"all ports are allocated"** and connections fail. So in compose, map `8443`
only, and let `PUBLISHED_PORT_RANGE=51000-51100` govern the child ports.

The default range is `32768-65535`, which is far too large to forward through a
home gateway. Shrinking it to a small block (I used `51000-51100`, 101 ports) is
what makes the port forward practical.

**2. Give the Colima VM enough vCPUs.** Speedify has a "unified metric" capacity
gate that rejects new connections when load average per vCPU is too high. A
1- or 2-vCPU VM will get rejected under any real load. Give the VM **at least 4
vCPUs**.

### THE KEY PROBLEM -- Colima's default networking kills the session

With a default `colima start` (shared/user-mode networking), remote clients
**could not connect**. The client would sit there and eventually report the
session timed out.

Here is the root cause. Colima (which uses Lima underneath) forwards container
ports from the Mac into the VM **over SSH**. SSH port forwarding carries **TCP
only, no UDP**. Speedify's session transport is **UDP**. So:

- The TCP API on `8443` worked. The handshake succeeded.
- The UDP session traffic never reached the VM, because SSH cannot forward UDP.
- The dynamically-assigned child TCP ports were also unreliable through that
  same forwarding layer.

End result: API connects, session times out. It looks like a firewall or a
Speedify config error, but it is the macOS Docker-in-a-VM port-forwarding layer
silently dropping UDP.

### THE SOLUTION -- bridged Colima networking + a preferred route

Start Colima with **bridged networking** and force the bridged interface to be
the VM's default route:

```sh
colima start \
  --network-mode bridged \
  --network-interface <LAN_IFACE> \
  --network-preferred-route \
  --cpu 4 \
  --memory 5
```

What each piece does:

- `--network-mode bridged` gives the Colima VM its **own IP on your LAN**, as a
  real DHCP device. Now container ports (UDP and the dynamic child range) are
  reachable **directly**, with no SSH-forward hop in the way. This is what fixes
  the UDP problem.
- `--network-interface <LAN_IFACE>` is the Mac's physical LAN interface to bridge
  onto (e.g. `en0`). Find it with `ifconfig` / `networksetup -listallhardwareports`.
- `--network-preferred-route` is **required**, not optional. Without it the VM
  has **asymmetric routing**: inbound packets arrive on the bridged interface,
  but outbound packets leave via Lima's internal NAT. That asymmetry breaks both
  the UDP session and the container's outbound NAT. The tell is that the error
  *changes*: instead of "timed out connecting to the server", the client gets a
  server-side **"Could not retrieve account login details"**, because the
  server's own outbound path is broken. If you see that error, you forgot this
  flag.
- `--cpu 4 --memory 5` clears the vCPU capacity gate described above.

After this, give the VM a **DHCP reservation** on your router so its bridged LAN
IP (`<VM_LAN_IP>`) is stable.

### The router port forward

Forward inbound traffic from the WAN to the VM's bridged LAN IP. Full details
(GL UI + UCI CLI + DDNS) are in `flint3-port-forward.md`. The rules:

| Purpose            | External port(s) | Protocol  | -> Internal (`<VM_LAN_IP>`) |
|--------------------|------------------|-----------|-----------------------------|
| Speedify API       | 8443             | TCP       | 8443                        |
| Session transport  | 51000-51100      | **TCP**   | 51000-51100                 |
| Session transport  | 51000-51100      | **UDP**   | 51000-51100                 |

Forward the session range for **both TCP and UDP**. The UDP half is the part
that matters and the part people skip.

Finally, set `PUBLIC_IP` in `docker-compose.yml` to your WAN public IP (or a
DDNS hostname that tracks it) so the server advertises a reachable address, and
bounce the stack.

### Point the Mudi at it

On the Mudi (the client):

```sh
speedify_cli show servers
speedify_cli connect "#<tag>"     # leading # locks to your server, no fallback
```

Then from a device behind the Mudi, check your IP at any "what is my IP" site.
It should show your **home IP**.

### Result

A remote client (the Mudi on cellular, off-site) connects to the home self-
hosted server and **egresses with the home IP**, while still bonding its links.
Verified working.

### Honest caveats

- **On cellular travel, your ceiling is the cellular UPLOAD**, not the server.
  My bonded cellular uplink was around **5-6 Mbps up**, so self-hosting does not
  buy you more speed on the road. Its value is the **home IP**, full stop. If you
  want raw speed, bond to Speedify's public servers instead.
- **The Mac must stay awake.** It is the server. If it sleeps, the tunnel dies.
  Set the power settings to keep it on.
- **Added latency.** Routing out through home adds a hop and the round-trip to
  wherever you are. Interactive latency goes up.
- **Hard dependency on a non-CGNAT public IP.** If your home connection is
  CGNAT (WAN IP in `100.64.0.0/10`, or it does not match what a public IP
  checker reports), this will not work without a relay or VPS tunnel. Confirm
  before buying the license.
- **The Intel-Mac-on-Colima host is fine.** A bare-metal Linux mini PC (Intel
  N100, around $150, native Docker, no VM and none of the Colima gotchas) is an
  **optional** upgrade for more headroom, not a requirement. The Colima setup
  works; I am running it.

---

## Files in this repo

| File                       | What it is |
|----------------------------|------------|
| `README.md`                | This guide. |
| `docker-compose.yml`       | The `speedify/ss-manager` service (amd64), API on 8443, session range 51000-51100. |
| `na-on` / `na-off`         | Manual Network Acceleration (flow offloading) toggles for the Mudi. |
| `speedify-na-watch`        | Watcher loop: polls Speedify state, flips flow offloading to match. |
| `speedify-na-watch.init`   | procd init script to run the watcher as a managed service. |
| `flint3-port-forward.md`   | Edge-router port-forward rules (GL UI + UCI CLI) and DDNS notes. |
