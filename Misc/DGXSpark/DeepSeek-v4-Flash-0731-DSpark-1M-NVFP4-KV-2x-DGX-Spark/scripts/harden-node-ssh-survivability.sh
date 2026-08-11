#!/usr/bin/env bash
set -euo pipefail

# One-time host hardening to keep SSH responsive during DSpark crashes/OOM spikes.
# Run directly on each DGX Spark node as root (or via sudo).

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

echo "== write sshd service override =="
install -d -m 0755 /etc/systemd/system/ssh.service.d
cat >/etc/systemd/system/ssh.service.d/99-survivability.conf <<'EOF'
[Service]
Restart=always
RestartSec=2s
OOMScoreAdjust=-1000
Nice=-5
CPUWeight=10000
TasksMax=infinity
EOF

echo "== write logind service override =="
install -d -m 0755 /etc/systemd/system/systemd-logind.service.d
cat >/etc/systemd/system/systemd-logind.service.d/99-survivability.conf <<'EOF'
[Service]
Restart=always
RestartSec=2s
OOMScoreAdjust=-900
Nice=-5
CPUWeight=10000
EOF

echo "== write memory/network safety sysctls =="
cat >/etc/sysctl.d/99-dspark-ssh-survivability.conf <<'EOF'
# Keep some free memory reserved so sshd/logind survive host pressure.
vm.min_free_kbytes=262144
# Prefer reclaim/swap before abruptly killing critical daemons.
vm.swappiness=80
# Avoid panic loops from userspace crashes.
kernel.panic_on_oops=0
kernel.panic=0
# Shorten dead TCP cleanup during network stress.
net.ipv4.tcp_fin_timeout=30
EOF

echo "== apply config =="
systemctl daemon-reload
sysctl --system >/dev/null

# Restart services so overrides apply now.
systemctl restart ssh
systemctl restart systemd-logind

echo "== verify =="
systemctl --no-pager --full status ssh | sed -n '1,30p'
systemctl --no-pager --full status systemd-logind | sed -n '1,30p'

echo "== done =="
echo "Node hardening applied. Repeat on the other node."
