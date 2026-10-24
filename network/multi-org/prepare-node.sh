#!/usr/bin/env bash
# Prepares a Raspberry Pi (Ubuntu Server 22.04+, 64-bit) to host Fabric containers.
# Run ON the Pi, as a normal user with sudo:   bash prepare-node.sh
# Idempotent: safe to run again.
#
#   - Docker Engine + compose plugin (official repository)
#   - swap file when RAM is small (the peer builds the Go chaincode image on install)
#   - chrony (NTP): peers and the load generator need synchronized clocks
#   - CPU governor "performance" and docker log rotation, for repeatable measurements
#   - Wi-Fi power saving off (only when the Pi is on Wi-Fi), to cut latency spikes
set -euo pipefail

SWAP_GB="${SWAP_GB:-}"

[ "$(uname -m)" = aarch64 ] || { echo "64-bit OS required (uname -m = $(uname -m)); Fabric images are arm64/amd64 only"; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "run as a normal user with sudo, not as root"; exit 1; }

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
echo ">> $(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0'), ${mem_mb} MB RAM"

echo ">> Installing Docker Engine"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
sudo usermod -aG docker "$USER"

echo ">> Docker log rotation"
sudo mkdir -p /etc/docker
echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' | sudo tee /etc/docker/daemon.json >/dev/null
sudo systemctl restart docker

echo ">> Time synchronization (chrony)"
sudo apt-get install -y chrony
sudo systemctl enable --now chrony

echo ">> CPU governor: performance"
sudo tee /etc/systemd/system/cpu-performance.service >/dev/null <<'UNIT'
[Unit]
Description=Set the CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-performance.service

# Wi-Fi power saving parks the radio between packets and adds latency spikes (hundreds of ms on sparse traffic).
# Turn it off when the default route uses a wireless interface; harmless to skip when the Pi is on Ethernet.
iface=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
if [ -n "$iface" ] && [ -d "/sys/class/net/$iface/wireless" ]; then
  echo ">> Wi-Fi power saving off on $iface"
  sudo apt-get install -y iw
  sudo tee /etc/systemd/system/wifi-powersave-off.service >/dev/null <<UNIT
[Unit]
Description=Disable Wi-Fi power saving
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iw dev $iface set power_save off'

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now wifi-powersave-off.service
  iw dev "$iface" get power_save || true
fi

# Default: 2 GB of swap below 2 GB of RAM (Pi 3), none otherwise. Override with SWAP_GB=<n>.
if [ -z "$SWAP_GB" ]; then
  if [ "$mem_mb" -lt 2048 ]; then SWAP_GB=2; else SWAP_GB=0; fi
fi
if [ "$SWAP_GB" -gt 0 ] && ! swapon --show=NAME --noheadings | grep -q .; then
  echo ">> Creating ${SWAP_GB} GB swap file (needed while the peer compiles the chaincode)"
  sudo fallocate -l "${SWAP_GB}G" /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
  sudo sysctl -q -p /etc/sysctl.d/99-swappiness.conf
fi

echo
echo "Done. Log out and back in (or run 'newgrp docker') so the docker group applies, then check:"
echo "  docker run --rm hello-world && docker compose version"
echo "  chronyc tracking | head -3"
echo "  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
free -h
