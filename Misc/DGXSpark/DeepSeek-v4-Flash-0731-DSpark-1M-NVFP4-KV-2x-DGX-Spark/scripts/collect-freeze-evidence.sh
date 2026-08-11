#!/usr/bin/env bash
set -euo pipefail

# Collect host + runtime evidence after a DSpark/SSH freeze.
# Usage:
#   sudo bash ./collect-freeze-evidence.sh
# Optional env:
#   WINDOW_MIN=180 OUT_DIR=/tmp/dspark-freeze-evidence-<host>-<ts>

WINDOW_MIN="${WINDOW_MIN:-180}"
HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-/tmp/dspark-freeze-evidence-${HOST}-${TS}}"

mkdir -p "${OUT_DIR}"

run_cmd() {
  local name="$1"
  shift
  {
    echo "### CMD: $*"
    echo "### TS: $(date -Is)"
    "$@"
  } >"${OUT_DIR}/${name}.txt" 2>&1 || true
}

run_timeout() {
  local sec="$1"
  shift
  local name="$1"
  shift
  {
    echo "### CMD: timeout ${sec} $*"
    echo "### TS: $(date -Is)"
    timeout "${sec}" "$@"
  } >"${OUT_DIR}/${name}.txt" 2>&1 || true
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "WARNING: not running as root; some logs may be incomplete" >"${OUT_DIR}/warnings.txt"
fi

# System identity + uptime
run_cmd 00-hostname hostnamectl
run_cmd 01-uname uname -a
run_cmd 02-uptime uptime
run_cmd 03-date date -Is
run_cmd 04-last-reboot last -x -n 20
run_cmd 05-who who -a

# CPU / memory / pressure
run_cmd 10-free free -h
run_cmd 11-vmstat vmstat -w 1 5
run_cmd 12-meminfo cat /proc/meminfo
run_cmd 13-pressure cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io
run_cmd 14-top-procs-mem ps -eo pid,ppid,user,%cpu,%mem,rss,vsz,stat,lstart,etime,cmd --sort=-%mem
run_cmd 15-top-procs-cpu ps -eo pid,ppid,user,%cpu,%mem,rss,vsz,stat,lstart,etime,cmd --sort=-%cpu

# Kernel / journald signals
run_timeout 20 20-dmesg-tail dmesg -T
run_timeout 20 21-dmesg-errors sh -lc "dmesg -T | egrep -i 'oom|out of memory|killed process|hung task|soft lockup|hard lockup|rcu|blocked for more than|nvrm|xid|nvlink|pcie|ext4|call trace|watchdog'"
run_timeout 30 22-journal-kernel sh -lc "journalctl -k --since '-${WINDOW_MIN} min' --no-pager"
run_timeout 30 23-journal-ssh sh -lc "journalctl -u ssh -u sshd --since '-${WINDOW_MIN} min' --no-pager"
run_timeout 30 24-journal-docker sh -lc "journalctl -u docker -u containerd --since '-${WINDOW_MIN} min' --no-pager"
run_timeout 30 25-journal-critical sh -lc "journalctl --since '-${WINDOW_MIN} min' --no-pager | egrep -i 'oom|killed process|soft lockup|hard lockup|hung task|rcu|watchdog|segfault|nvcc|nvidia|xid|ssh|containerd|docker'"

# Network / ssh state
run_cmd 30-ip-addr ip -br a
run_cmd 31-ip-route ip route
run_cmd 32-ss-summary ss -s
run_cmd 33-ss-22 sh -lc "ss -ltnp | egrep ':22\b|State'"
run_cmd 34-nftables sh -lc "command -v nft >/dev/null && nft list ruleset || true"

# Docker / containers
if command -v docker >/dev/null 2>&1; then
  run_cmd 40-docker-ps docker ps -a
  run_timeout 20 41-docker-stats docker stats --no-stream
  run_cmd 42-docker-info docker info
  run_cmd 43-docker-inspect-head sh -lc "docker inspect dspark-head 2>/dev/null || true"
  run_cmd 44-docker-inspect-worker sh -lc "docker inspect dspark-worker 2>/dev/null || true"
  run_cmd 45-docker-logs-head sh -lc "docker logs --tail 500 dspark-head 2>/dev/null || true"
  run_cmd 46-docker-logs-worker sh -lc "docker logs --tail 500 dspark-worker 2>/dev/null || true"
fi

# GPU state
if command -v nvidia-smi >/dev/null 2>&1; then
  run_cmd 50-nvidia-smi nvidia-smi
  run_cmd 51-nvidia-proc sh -lc "nvidia-smi pmon -c 1"
  run_cmd 52-nvidia-query sh -lc "nvidia-smi --query-gpu=timestamp,name,temperature.gpu,utilization.gpu,utilization.memory,memory.total,memory.used,power.draw,clocks.sm --format=csv,noheader"
fi

# Services
run_cmd 60-systemctl-failed systemctl --failed
run_cmd 61-ssh-status sh -lc "systemctl status ssh --no-pager || systemctl status sshd --no-pager || true"
run_cmd 62-docker-status sh -lc "systemctl status docker --no-pager || true"
run_cmd 63-containerd-status sh -lc "systemctl status containerd --no-pager || true"

# Persist metadata
{
  echo "OUT_DIR=${OUT_DIR}"
  echo "HOST=${HOST}"
  echo "TS=${TS}"
  echo "WINDOW_MIN=${WINDOW_MIN}"
} >"${OUT_DIR}/meta.env"

ARCHIVE="${OUT_DIR}.tar.gz"
tar -C "$(dirname "${OUT_DIR}")" -czf "${ARCHIVE}" "$(basename "${OUT_DIR}")"

echo "Evidence directory: ${OUT_DIR}"
echo "Evidence archive : ${ARCHIVE}"
