#!/usr/bin/env bash
# CPU sampler for this machine (macOS): the Mac also hosts a peer, two orderers and the load generator.
# Columns: epoch ms, user %, system %, idle %. `top` needs ~1 s per sample.
MAX_SECONDS="${1:-3600}"
echo "ts_ms,cpu_user_pct,cpu_sys_pct,cpu_idle_pct"
end=$(( $(date +%s) + MAX_SECONDS ))
while [ "$(date +%s)" -lt "$end" ]; do
  line=$(top -l 2 -s 1 -n 0 | grep "CPU usage" | tail -1)
  echo "$(python3 -c 'import time; print(int(time.time()*1000))'),$(echo "$line" | awk '{gsub("%","",$3); gsub("%","",$5); gsub("%","",$7); print $3","$5","$7}')"
done
