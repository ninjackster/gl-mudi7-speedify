#!/bin/zsh
exec >> "$HOME/speedify-autostart/boot.log" 2>&1
echo "=== speedify autostart $(date) ==="
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
for i in {1..40}; do /sbin/ping -c1 -t2 <ROUTER_LAN_IP> >/dev/null 2>&1 && break; sleep 2; done
sleep 45
for try in {1..6}; do
  echo "colima start attempt $try $(date)"
  if colima start; then echo "colima up on attempt $try"; break; fi
  colima stop >/dev/null 2>&1; sleep 25
done
sleep 5
colima ssh -- sudo ip route del default dev eth0 2>/dev/null
cd "$HOME/speedify-selfhosted" && docker compose up -d && sleep 8 && docker compose restart
colima ls
