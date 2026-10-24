#!/usr/bin/env bash
# Resource sampler for a Raspberry Pi. Sent over SSH on stdin (`ssh host 'bash -s -- 1 3600' < sampler.sh`);
# prints one CSV line per interval until it is killed (the next write to a closed SSH channel ends it) or
# MAX_SECONDS elapse.
#
# Columns: epoch ms, cpu busy %, iowait %, load1, mem available MB, swap used MB, temperature C, CPU MHz,
#          throttled (clock below 95% of max), undervoltage alarm now (1/0, -1 if unknown),
#          SD read/write kB/s, network rx/tx kB/s on the default interface.
INTERVAL="${1:-1}"
MAX_SECONDS="${2:-3600}"

# the rpi_volt hwmon device raises in0_lcrit_alarm while the supply voltage is too low
volt_dir=""
for d in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$d/name" 2>/dev/null)" = rpi_volt ] && volt_dir="$d" && break
done
max_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0)
iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)

echo "ts_ms,cpu_pct,iowait_pct,load1,mem_avail_mb,swap_used_mb,temp_c,freq_mhz,throttled,uv_alarm,sd_read_kbs,sd_write_kbs,net_rx_kbs,net_tx_kbs"

read -r _ u n s idle iow irq sirq steal _ < /proc/stat
prev_total=$((u + n + s + idle + iow + irq + sirq + steal)); prev_idle=$idle; prev_iow=$iow
read -r prev_sr prev_sw < <(awk '$3=="mmcblk0"{print $6, $10}' /proc/diskstats)
prev_rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
prev_tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
prev_ms=$(date +%s%3N)
end=$(( $(date +%s) + MAX_SECONDS ))

while [ "$(date +%s)" -lt "$end" ]; do
  sleep "$INTERVAL"
  read -r _ u n s idle iow irq sirq steal _ < /proc/stat
  total=$((u + n + s + idle + iow + irq + sirq + steal))
  dt=$((total - prev_total)); [ "$dt" -gt 0 ] || dt=1
  cpu=$(( 1000 * (dt - (idle - prev_idle)) / dt ))        # tenths of a percent
  iowp=$(( 1000 * (iow - prev_iow) / dt ))
  prev_total=$total; prev_idle=$idle; prev_iow=$iow

  now_ms=$(date +%s%3N); el=$((now_ms - prev_ms)); [ "$el" -gt 0 ] || el=1; prev_ms=$now_ms
  read -r sr sw < <(awk '$3=="mmcblk0"{print $6, $10}' /proc/diskstats)
  rkbs=$(( (sr - prev_sr) * 512 * 1000 / 1024 / el )); wkbs=$(( (sw - prev_sw) * 512 * 1000 / 1024 / el ))
  prev_sr=$sr; prev_sw=$sw
  rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
  rxk=$(( (rx - prev_rx) * 1000 / 1024 / el )); txk=$(( (tx - prev_tx) * 1000 / 1024 / el ))
  prev_rx=$rx; prev_tx=$tx

  mem=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  swap=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)
  temp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
  thr=0; [ "$max_khz" -gt 0 ] && [ $((khz * 100)) -lt $((max_khz * 95)) ] && thr=1
  uv=-1; [ -n "$volt_dir" ] && uv=$(cat "$volt_dir/in0_lcrit_alarm" 2>/dev/null || echo -1)
  load=$(cut -d' ' -f1 /proc/loadavg)

  echo "$now_ms,$((cpu / 10)).$((cpu % 10)),$((iowp / 10)).$((iowp % 10)),$load,$mem,$swap,$temp,$((khz / 1000)),$thr,$uv,$rkbs,$wkbs,$rxk,$txk"
done
