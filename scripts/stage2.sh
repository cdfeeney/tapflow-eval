#!/bin/bash
# Stage 2: hold the same relay open through a tunnel so a real browser elsewhere can use the simulator.
R="$PWD/results"
brew install cloudflared > "$R/cloudflared-install.log" 2>&1
nohup cloudflared tunnel --no-autoupdate --url http://localhost:4000 > "$R/cloudflared.log" 2>&1 &
for _ in $(seq 1 30); do
  URL=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$R/cloudflared.log" | head -1)
  [ -n "$URL" ] && break; sleep 2
done
echo "TUNNEL_URL=$URL"
end=$((SECONDS + HOLD_MINUTES * 60))
while [ $SECONDS -lt $end ]; do
  top -l 1 -n 0 | grep -E "CPU usage|PhysMem" | tr '\n' ' ' >> "$R/resources.txt"; echo >> "$R/resources.txt"
  [ -z "$(curl -s -m 5 localhost:4000/api/v1/auth/status)" ] && echo "relay down at $SECONDS" >> "$R/resources.txt"
  sleep 20
done
