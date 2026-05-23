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
# Pin the bridged col0 default route. A bare boot-time delete of eth0's default
# is not durable (it comes back on DHCP renewal), so route-fix.sh installs a
# metric-50 col0 default that wins even after eth0 re-adds its own. The
# com.user.speedify-routefix LaunchAgent then re-enforces this every 120s.
"$HOME/speedify-autostart/route-fix.sh"
cd "$HOME/speedify-selfhosted" && docker compose up -d && sleep 8 && docker compose restart
colima ls
