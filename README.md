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

## Auto-start on boot (set-and-forget)

Getting the server working once is one thing. Making it come back on its own
after a reboot or a power blip took more work than I expected, because two things
quietly break on resume. Here is the full picture for surviving a reboot
unattended.

### Finding 1 -- `--network-preferred-route` does NOT persist across a reboot

This is the one that bites you. The flag works the first time you start Colima,
but it is not durable. Every `colima start` (a resume of the existing VM)
resurrects Lima's internal-NAT default route on `eth0` (the internal
`192.168.x.x` interface) at a **lower metric** than the bridged `col0`. So the
asymmetric routing I fought during the initial setup comes right back on every
boot: inbound arrives on the bridged interface, outbound tries to leave via the
internal NAT.

The symptoms are the same two I saw before:

- The client connect goes from working to **"timed out"**, or
- The server logs **"Could not retrieve account login details"** -- its own
  outbound to Speedify's cloud is broken by the bad route.

The fix, applied **on every boot**: after `colima start`, delete the `eth0`
default so the bridged interface is the sole default route, then bounce the
server so it re-establishes its cloud connections over the correct path:

```sh
colima ssh -- sudo ip route del default dev eth0
docker compose restart
```

The boot script below does both automatically. **But note:** deleting the `eth0`
default at boot is necessary but **not sufficient on its own** -- the route comes
back at runtime on the next DHCP lease renewal. See the "Critical: keep the VM's
default route on the bridge" section below for the durable fix that survives
renewals.

### Finding 2 -- vz fails to start under heavy early-boot load

The first time I wired up auto-start, it failed. The cause: the LaunchAgent
fired the instant the user session came up, while the box was still thrashing
through login (load average around 29). The vz backend
(Apple's Virtualization.framework) does not tolerate that -- the VM exited
immediately on `colima start`.

The fix is to be patient and to retry. The boot script waits for the LAN gateway
to answer, sleeps about 45 seconds to let the early-boot load settle, and then
retries `colima start` up to 6 times, stopping and pausing between attempts.

### Finding 3 -- use a USER LaunchAgent + auto-login, NOT a root LaunchDaemon

This is the non-obvious part. The natural instinct is a root `LaunchDaemon` so it
runs at boot before anyone logs in. That does **not** work here: the vz backend
needs a real user GUI session, which a root LaunchDaemon does not provide. A
**LaunchAgent** runs inside the user's login session, which is what vz wants.

That means the Mac has to actually log a user in on its own. Requirements:

- **Auto-login enabled** (System Settings -> Users & Groups -> automatically log
  in as your user) so a GUI session exists after a reboot.
- **FileVault OFF.** With FileVault on, the disk is locked at boot until someone
  types the password, so nothing auto-starts. It has to be off for unattended
  boot.

You do **not** need to give the LaunchAgent any sudo rights for the bridge.
Colima already installs `/etc/sudoers.d/colima` for `socket_vmnet` the first time
you start with bridged networking, so the bridged start is passwordless. The
`ip route del` step runs inside the VM via `colima ssh -- sudo ...`, which is
also fine without host sudo.

### Finding 4 -- clamshell / headless

If the Mac runs lid-closed (mine does), keep it awake with:

```sh
sudo pmset -a disablesleep 1
```

Confirm it took with `pmset -g | grep SleepDisabled` -- you want `SleepDisabled 1`.
This keeps the lid-closed machine from sleeping and killing the tunnel.

### Putting it together

Two files in this repo wire all of the above:

- `start.sh` -- the hardened boot script. It waits for the gateway, lets load
  settle, retries `colima start`, calls `route-fix.sh` to pin the bridged default
  route, then brings up and restarts the stack. It logs to
  `~/speedify-autostart/boot.log` so you can see what happened on the last boot.
- `com.user.speedify-selfhosted.plist` -- the LaunchAgent that runs `start.sh` at
  login. Drop it in `~/Library/LaunchAgents/`, edit the paths for your user, and
  load it:

  ```sh
  launchctl load ~/Library/LaunchAgents/com.user.speedify-selfhosted.plist
  ```

After that, with auto-login on and FileVault off, the server stands itself back
up after a reboot with no hands on the keyboard.

---

## Critical: keep the VM's default route on the bridge (DHCP-renewal reversion)

This is the failure that took me the longest to find, because it does not show up
at boot. The tunnel comes up clean, runs fine for a day or two, and then **dies
on its own with no reboot and no change on my end**. If you only do the boot-time
`ip route del default dev eth0` from the auto-start section above, you will hit
this. A one-shot fix at boot is **not** enough.

### Root cause

The Colima VM has two interfaces: `eth0` (Lima's internal user-NAT) and `col0`
(the bridged LAN interface I added for self-hosting). The bridged `col0` gets its
LAN address by DHCP from my router. When that **DHCP lease renews** (hours after
boot, on the lease's own schedule), Lima's `eth0` re-adds its **own default
route** at metric 200. That outranks the bridged `col0` default at metric 300, so
the VM silently flips back to **asymmetric routing**: inbound packets still arrive
on `col0` via the port-forward, but outbound now leaves via `eth0`'s NAT.

That asymmetry is exactly what breaks Speedify's UDP session. The handshake on the
TCP API still looks fine, but the UDP session traffic returns on the wrong path
and the session quietly drops. From the outside it looks like the server "just
stopped working days later" with nothing to point at. There is nothing in the
logs at the moment it breaks, because nothing crashed: the route just moved.

The boot-time `ip route del default dev eth0` does not survive this, because the
re-add happens at runtime on the next lease renewal, long after the boot script
has finished.

### The durable fix (three layers)

**1. Pin a low-metric `col0` default inside the VM.** Instead of just deleting the
`eth0` default (which comes back), replace the `col0` default with a metric *lower*
than whatever `eth0` re-adds:

```sh
colima ssh -- sudo ip route replace default via <ROUTER_LAN_IP> dev col0 metric 50
```

Metric 50 beats `eth0`'s metric 200, so even when `eth0` re-adds its default on a
DHCP renewal, `col0` stays the winning default route. This alone eliminates the
breakage. Verify the VM is actually choosing the bridge for outbound:

```sh
colima ssh -- ip route get 1.1.1.1   # should show dev col0, not eth0
```

**2. A periodic watchdog (macOS LaunchAgent).** Routes can still get flushed (a
full lease drop, a network blip), so I enforce the rule on a timer rather than
trusting it to hold forever. `route-fix.sh` re-applies the two route commands, and
`com.user.speedify-routefix.plist` runs it every 120 seconds via `StartInterval`
(plus `RunAtLoad`). It runs as a **user LaunchAgent**, so it needs **no macOS
sudo**: the `sudo` inside the commands is passwordless *inside the Lima VM*, which
is what `colima ssh -- sudo ...` invokes.

The watchdog self-heals against renewals and flushes: within two minutes of any
reversion, the metric-50 `col0` default is back and the session is fine.

**Gotcha: do NOT pass a quoted compound command to `colima ssh`.** A single call
like `colima ssh -- "ip route del default dev eth0; ip route replace ..."` does
**not** work the way you would expect; the quoted compound breaks under
`colima ssh`. Use **two separate `colima ssh --` calls**, one per command, which is
exactly what `route-fix.sh` does:

```sh
colima ssh -- sudo ip route del default dev eth0 2>/dev/null
colima ssh -- sudo ip route replace default via <ROUTER_LAN_IP> dev col0 metric 50 2>/dev/null
```

**3. Wire it into `start.sh`.** The boot script calls `route-fix.sh` right after
`colima start`, so the correct route is in place the instant the VM is up, before
the watchdog's first interval even fires.

### Install the watchdog

Drop `route-fix.sh` in `~/speedify-autostart/`, edit `<ROUTER_LAN_IP>` to your
router's LAN gateway, make it executable, drop the plist in
`~/Library/LaunchAgents/` with the paths edited for your user, then bootstrap it:

```sh
chmod +x ~/speedify-autostart/route-fix.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.speedify-routefix.plist
```

Check it is running and watch it work:

```sh
launchctl print gui/$(id -u)/com.user.speedify-routefix | grep state
tail -f ~/speedify-autostart/routefix.log
```

With the metric-50 route, the watchdog, and the `start.sh` wiring all in place,
the "works at first, dies days later" failure is gone. The VM's default route
stays on the bridge no matter how many times the DHCP lease renews.

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
| `start.sh`                 | Hardened boot script: waits for the gateway, retries `colima start`, pins the bridged default route via `route-fix.sh`, brings up the stack. |
| `com.user.speedify-selfhosted.plist` | LaunchAgent that runs `start.sh` at login (pair with auto-login + FileVault off). |
| `route-fix.sh`             | Re-pins the metric-50 `col0` default route in the VM so a DHCP-renewal `eth0` re-add cannot break Speedify's UDP session. |
| `com.user.speedify-routefix.plist` | LaunchAgent that runs `route-fix.sh` every 120s as a watchdog against route reversion. |
