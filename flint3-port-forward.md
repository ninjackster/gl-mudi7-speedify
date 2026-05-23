# Edge Router Port Forwarding for the Speedify Self-Hosted Server

In my setup the edge router is a GL.iNet Flint 3 (GL-BE9300) on AT&T Fiber with
IP Passthrough, so the router holds the public IP. Whatever your edge router is,
it has to forward inbound WAN traffic to the machine running the Speedify server
(in my case the Colima VM's bridged LAN IP on the Intel Mac).

The same three rules apply to any OpenWrt-based GL.iNet router. Adjust the admin
IP and interface names to match yours.

## Ports to forward (WAN -> server LAN IP)

| Purpose            | External port(s) | Protocol | -> Internal port(s) |
|--------------------|------------------|----------|---------------------|
| Speedify API       | 8443             | TCP      | 8443                |
| Session transport  | 51000-51100      | TCP      | 51000-51100         |
| Session transport  | 51000-51100      | UDP      | 51000-51100         |

> Replace `<SERVER_LAN_IP>` everywhere below with the actual LAN address of the
> box (or VM) running the server. If you run the server in a **bridged** Colima
> VM (see the main README), this is the **VM's own DHCP IP on the LAN**, not the
> Mac's IP. Find it with `colima ls` / `colima status`, or in the GL.iNet UI
> under **Clients**. Give it a **static DHCP reservation** so it never changes.

The session range must be forwarded for **both TCP and UDP**. The UDP half is
the part everyone forgets, and Speedify's session transport is UDP, so leaving
it out is the single most common reason a remote client never connects.

---

## (a) GL.iNet Web UI

1. Browse to the router admin (default `http://<ROUTER_LAN_IP>`, e.g.
   `http://192.168.8.1`) and log in.
2. Go to **Network -> Port Forwarding** (on some firmware: **Firewall ->
   Port Forwards**).
3. Click **Add New** and create three rules:

   **Rule 1 -- API (TCP 8443)**
   - Name: `speedify-api`
   - Protocol: `TCP`
   - External / Source port: `8443`
   - Internal / Destination IP: `<SERVER_LAN_IP>`
   - Internal / Destination port: `8443`

   **Rule 2 -- Session TCP (51000-51100)**
   - Name: `speedify-session-tcp`
   - Protocol: `TCP`
   - External / Source port: `51000-51100`
   - Internal / Destination IP: `<SERVER_LAN_IP>`
   - Internal / Destination port: `51000-51100`

   **Rule 3 -- Session UDP (51000-51100)**
   - Name: `speedify-session-udp`
   - Protocol: `UDP`
   - External / Source port: `51000-51100`
   - Internal / Destination IP: `<SERVER_LAN_IP>`
   - Internal / Destination port: `51000-51100`

4. Save / Apply. The firewall reloads automatically.

> If the GL.iNet UI only exposes single-port forwards, drop into **LuCI**
> (Advanced / OpenWrt admin) for the port-range rules, or use the CLI below.

---

## (b) UCI CLI (SSH into the router)

SSH in (`ssh root@<ROUTER_LAN_IP>`) and paste the blocks below. Set the LAN IP
first with `export SERVER_LAN_IP=<SERVER_LAN_IP>` and the commands pick it up.

```sh
# --- Rule 1: API, TCP 8443 -> server 8443 ---
uci add firewall redirect
uci set firewall.@redirect[-1].name='speedify-api'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].src_dport='8443'
uci set firewall.@redirect[-1].dest_ip="$SERVER_LAN_IP"
uci set firewall.@redirect[-1].dest_port='8443'
uci set firewall.@redirect[-1].target='DNAT'

# --- Rule 2: Session transport, TCP 51000-51100 ---
uci add firewall redirect
uci set firewall.@redirect[-1].name='speedify-session-tcp'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].src_dport='51000-51100'
uci set firewall.@redirect[-1].dest_ip="$SERVER_LAN_IP"
uci set firewall.@redirect[-1].dest_port='51000-51100'
uci set firewall.@redirect[-1].target='DNAT'

# --- Rule 3: Session transport, UDP 51000-51100 ---
uci add firewall redirect
uci set firewall.@redirect[-1].name='speedify-session-udp'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].proto='udp'
uci set firewall.@redirect[-1].src_dport='51000-51100'
uci set firewall.@redirect[-1].dest_ip="$SERVER_LAN_IP"
uci set firewall.@redirect[-1].dest_port='51000-51100'
uci set firewall.@redirect[-1].target='DNAT'

# Commit and reload the firewall.
uci commit firewall
/etc/init.d/firewall restart
```

Verify the rules took:

```sh
uci show firewall | grep -A8 redirect | grep -i speedify
```

To remove a rule later, find its index with `uci show firewall` and
`uci delete firewall.@redirect[N]` then commit + restart.

---

## DDNS (so PUBLIC_IP can follow a changing WAN IP)

Residential WAN IPs can change. Use a hostname (on a domain you own) instead of
a bare IP wherever possible, and feed that into `PUBLIC_IP` resolution.

Options, easiest first:

1. **GL.iNet built-in DDNS** -- **Applications -> Dynamic DNS** in the GL UI.
   Gives a free `*.glddns.com` hostname out of the box; quickest to stand up.
2. **Cloudflare DDNS (uses your own domain)** -- if the domain is on Cloudflare,
   run a Cloudflare DDNS updater so an A record (e.g. `home.yourdomain.com`)
   tracks the WAN IP. Either install **ddns-go** as a package on the router (it
   ships on many GL builds) pointed at a Cloudflare API token + zone, or run the
   updater on an always-on machine via cron or a small container.
3. **OpenWrt `ddns-scripts`** via LuCI -- native, supports Cloudflare and many
   providers; configure under **Services -> Dynamic DNS** in LuCI.

After DDNS is live, set `PUBLIC_IP` in `docker-compose.yml` to the current WAN
IP (or script it to resolve the DDNS hostname), then bounce the stack. Re-check
it if your ISP ever hands you a new address.
