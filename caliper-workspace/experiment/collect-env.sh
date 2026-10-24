#!/usr/bin/env bash
# Writes environment.md: hardware, software and network conditions of every node, for the methodology section
# and so that results can be compared fairly. Usage: collect-env.sh <output.md>
set -uo pipefail
OUT="${1:?usage: collect-env.sh <output.md>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../network/multi-org/inventory.env"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)

pi_info() {
  local name="$1" user="$2" host="$3"
  echo "### $name ($host)"; echo '```'
  "${SSH[@]}" "$user@$host" '
    iface=$(ip -o -4 route show to default | awk "{print \$5}" | head -1)
    echo "model:      $(tr -d "\0" < /sys/firmware/devicetree/base/model)"
    echo "os/kernel:  $(. /etc/os-release; echo $PRETTY_NAME) / $(uname -r) $(uname -m)"
    echo "cpu:        $(lscpu | awk -F: "/Model name/{gsub(/^ +/,\"\",\$2); print \$2}") x$(nproc), max $(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) / 1000 )) MHz, governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    echo "memory:     $(free -m | awk "/Mem:/{print \$2}") MB RAM, $(free -m | awk "/Swap:/{print \$2}") MB swap"
    echo "storage:    $(findmnt -no SOURCE /) $(lsblk -dno SIZE,TYPE $(findmnt -no SOURCE / | sed "s/p[0-9]*$//") 2>/dev/null | head -1); card: $(cat /sys/block/mmcblk0/device/name 2>/dev/null) manfid $(cat /sys/block/mmcblk0/device/manfid 2>/dev/null) date $(cat /sys/block/mmcblk0/device/date 2>/dev/null)"
    echo "docker:     $(docker --version 2>&1)"
    echo "network:    interface $iface, $( [ -d /sys/class/net/$iface/wireless ] && echo Wi-Fi || echo Ethernet ), speed $(cat /sys/class/net/$iface/speed 2>/dev/null || echo n/a) Mbit/s"
    command -v iw >/dev/null && [ -d /sys/class/net/$iface/wireless ] && iw dev $iface link 2>/dev/null | grep -E "SSID|freq|signal|tx bitrate" | sed "s/^/            /"
    echo "clock:      $(chronyc tracking 2>/dev/null | awk "/System time/{print \$4*1000\" ms from NTP, \"}")$(chronyc tracking 2>/dev/null | awk "/Leap status/{print \$4}")"
    echo "power:      $(journalctl -b -k --no-pager 2>/dev/null | grep -ciE "under-?voltage") undervoltage message(s) since boot; uptime $(uptime -p)"
    echo "temp now:   $(awk "{printf \"%.1f C\", \$1/1000}" /sys/class/thermal/thermal_zone0/temp)"
  ' 2>&1
  echo '```'; echo
}

rtt() {
  local label="$1"; shift
  printf -- "- %s: " "$label"
  "$@" 2>&1 | awk -F'[ =/]+' '/min\/avg\/max/{printf "min %s / avg %s / max %s / stddev %s ms\n", $(NF-4), $(NF-3), $(NF-2), $(NF-1)}' | head -1
}

{
  echo "# Environment"
  echo
  echo "Collected $(date -u +"%Y-%m-%d %H:%M:%S UTC")."
  echo
  echo "## Nodes"; echo
  pi_info "pi3 (peer0.org1, emergency)" "$PI3_USER" "$PI3_HOST"
  pi_info "pi5 (peer0.org2 + orderer1, hospital)" "$PI5_USER" "$PI5_HOST"
  echo "### mac (peer0.org3 + orderer2 + orderer3, audit; Caliper and gateway) ($MAC_HOST)"; echo '```'
  echo "model:      $(sysctl -n hw.model)  $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  echo "os:         macOS $(sw_vers -productVersion) $(uname -m)"
  echo "cpu/memory: $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM"
  echo "docker:     $(docker --version 2>&1); VM: $(docker info 2>/dev/null | grep -E 'CPUs|Total Memory' | tr -s ' ' | tr '\n' ';')"
  echo "network:    $(route -n get default 2>/dev/null | awk '/interface/{print $2}'), $(ifconfig en0 2>/dev/null | awk '/media:/{$1=""; print}')"
  echo '```'; echo
  echo "## Network latency (ICMP, 50 probes, snapshot: see rtt-*.txt of each step for the latency under load)"; echo
  rtt "mac -> pi3" ping -c 50 -i 0.2 "$PI3_HOST"
  rtt "mac -> pi5" ping -c 50 -i 0.2 "$PI5_HOST"
  rtt "pi5 -> pi3" "${SSH[@]}" "$PI5_USER@$PI5_HOST" "ping -c 50 -i 0.2 $PI3_HOST"
  echo
  echo "## Fabric"; echo '```'
  echo "images: $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'fabric-(peer|orderer)' | tr '\n' ' ')"
  echo "channel: auditchannel, 3 Raft orderers (1 on pi5, 2 on mac), batch timeout $(grep -m1 BatchTimeout "$HERE/../../network/multi-org/configtx.yaml" | awk '{print $2}'), max message count $(grep -m1 MaxMessageCount "$HERE/../../network/multi-org/configtx.yaml" | awk '{print $2}')"
  echo "endorsement policy: AND('Org1MSP.peer','Org2MSP.peer')"
  echo '```'
} > "$OUT"
echo "wrote $OUT"
