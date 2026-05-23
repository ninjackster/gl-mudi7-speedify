#!/bin/zsh
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
# Keep col0 (bridged LAN) the preferred default in the Colima VM.
# Lima eth0 (user-NAT) re-adds a lower-metric default on DHCP renewal,
# causing asymmetric routing that breaks Speedify UDP. Enforce every run.
colima ssh -- sudo ip route del default dev eth0 2>/dev/null
colima ssh -- sudo ip route replace default via <ROUTER_LAN_IP> dev col0 metric 50 2>/dev/null
echo "$(date) routes: $(colima ssh -- ip route show default 2>/dev/null | tr '\n' '|')"
