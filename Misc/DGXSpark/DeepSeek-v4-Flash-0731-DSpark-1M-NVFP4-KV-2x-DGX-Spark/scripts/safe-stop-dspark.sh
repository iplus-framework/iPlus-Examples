#!/usr/bin/env bash
set -euo pipefail

# Emergency stop helper for DSpark dual-node containers.
# Run this from node A (or any host with SSH access to node B).

SSH_USER="${SSH_USER:-gipsoft}"
WORKER_IP="${WORKER_IP:-192.168.100.11}"
SSH_KEY="${SSH_KEY:-/home/gipsoft/.ssh/id_ed25519_shared}"
STOP_TIMEOUT_SEC="${STOP_TIMEOUT_SEC:-8}"
REMOVE_TIMEOUT_SEC="${REMOVE_TIMEOUT_SEC:-8}"
KILL_TIMEOUT_SEC="${KILL_TIMEOUT_SEC:-8}"
DOCKER_PROBE_TIMEOUT_SEC="${DOCKER_PROBE_TIMEOUT_SEC:-3}"
FAIL_ON_UNREACHABLE="${FAIL_ON_UNREACHABLE:-1}"

sshw=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if [ -n "${SSH_KEY}" ] && [ -f "${SSH_KEY}" ]; then
  sshw+=( -i "${SSH_KEY}" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes )
fi
sshw+=( -o ConnectTimeout="${STOP_TIMEOUT_SEC}" )

log() {
  printf '%s\n' "$*"
}

remote_ssh_ok() {
  local host="$1"
  timeout "${STOP_TIMEOUT_SEC}" "${sshw[@]}" "${SSH_USER}@${host}" "echo ok" >/dev/null 2>&1
}

docker_cmd_local() {
  if timeout "${DOCKER_PROBE_TIMEOUT_SEC}" docker info >/dev/null 2>&1; then
    timeout "${STOP_TIMEOUT_SEC}" docker "$@"
    return
  fi
  timeout "${DOCKER_PROBE_TIMEOUT_SEC}" sudo -n docker info >/dev/null 2>&1 || return 1
  timeout "${STOP_TIMEOUT_SEC}" sudo -n docker "$@"
}

docker_cmd_remote() {
  local host="$1"
  shift
  timeout "${STOP_TIMEOUT_SEC}" "${sshw[@]}" "${SSH_USER}@${host}" "
set -e
if timeout ${DOCKER_PROBE_TIMEOUT_SEC} docker info >/dev/null 2>&1; then
  timeout ${STOP_TIMEOUT_SEC} docker $*
else
  timeout ${DOCKER_PROBE_TIMEOUT_SEC} sudo -n docker info >/dev/null 2>&1
  timeout ${STOP_TIMEOUT_SEC} sudo -n docker $*
fi
" >/dev/null 2>&1
}

get_local_container_pid() {
  docker_cmd_local inspect -f '{{.State.Pid}}' "$1" 2>/dev/null || true
}

get_local_container_id() {
  docker_cmd_local inspect -f '{{.Id}}' "$1" 2>/dev/null || true
}

container_running_local() {
  docker_cmd_local ps --format '{{.Names}}' 2>/dev/null | grep -E '^dspark-head$' >/dev/null
}

get_remote_container_pid() {
  local host="$1"
  local name="$2"
  timeout "${STOP_TIMEOUT_SEC}" "${sshw[@]}" "${SSH_USER}@${host}" "
if docker info >/dev/null 2>&1; then
  docker inspect -f '{{.State.Pid}}' ${name} 2>/dev/null || true
else
  sudo -n docker inspect -f '{{.State.Pid}}' ${name} 2>/dev/null || true
fi
" 2>/dev/null || true
}

hard_kill_local_pid() {
  local pid="$1"
  if [ -n "${pid}" ] && [ "${pid}" != "0" ]; then
    timeout "${KILL_TIMEOUT_SEC}" kill -TERM "${pid}" >/dev/null 2>&1 || true
    timeout "${KILL_TIMEOUT_SEC}" kill -KILL "${pid}" >/dev/null 2>&1 || true
  fi
}

hard_kill_local_pid_tree() {
  local root_pid="$1"
  if [ -z "${root_pid}" ] || [ "${root_pid}" = "0" ]; then
    return 0
  fi
  local child_pids
  child_pids="$(ps -o pid= --ppid "${root_pid}" 2>/dev/null || true)"
  for child in ${child_pids}; do
    hard_kill_local_pid_tree "${child}"
  done
  hard_kill_local_pid "${root_pid}"
}

hard_kill_local_shim_by_container_id() {
  local cid="$1"
  if [ -z "${cid}" ]; then
    return 0
  fi
  local shim_pids
  shim_pids="$(pgrep -f "containerd-shim.*${cid}" 2>/dev/null || true)"
  for spid in ${shim_pids}; do
    timeout "${KILL_TIMEOUT_SEC}" kill -TERM "${spid}" >/dev/null 2>&1 || true
    timeout "${KILL_TIMEOUT_SEC}" kill -KILL "${spid}" >/dev/null 2>&1 || true
  done
}

hard_kill_remote_pid() {
  local host="$1"
  local pid="$2"
  if [ -n "${pid}" ] && [ "${pid}" != "0" ]; then
    timeout "${KILL_TIMEOUT_SEC}" "${sshw[@]}" "${SSH_USER}@${host}" "kill -TERM ${pid} >/dev/null 2>&1 || true; kill -KILL ${pid} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
}

log "== local stop: dspark-head =="
LOCAL_PID_BEFORE="$(get_local_container_pid dspark-head)"
LOCAL_CID_BEFORE="$(get_local_container_id dspark-head)"
docker_cmd_local stop dspark-head >/dev/null 2>&1 || true
docker_cmd_local rm -f dspark-head >/dev/null 2>&1 || true
if container_running_local; then
  log "local: container still running, forcing kill"
  docker_cmd_local kill dspark-head >/dev/null 2>&1 || true
  hard_kill_local_pid_tree "${LOCAL_PID_BEFORE}"
  LOCAL_PID_AFTER="$(get_local_container_pid dspark-head)"
  hard_kill_local_pid_tree "${LOCAL_PID_AFTER}"
  hard_kill_local_shim_by_container_id "${LOCAL_CID_BEFORE}"
  docker_cmd_local rm -f --time 0 dspark-head >/dev/null 2>&1 || true
  docker_cmd_local rm -f dspark-head >/dev/null 2>&1 || true
fi

log "== remote stop: dspark-worker on ${WORKER_IP} =="
REMOTE_UNREACHABLE=0
if ! remote_ssh_ok "${WORKER_IP}"; then
  REMOTE_UNREACHABLE=1
  log "remote: ${WORKER_IP} unreachable via ssh (state unknown; cannot stop dspark-worker)"
fi
if [ "${REMOTE_UNREACHABLE}" = "0" ]; then
  REMOTE_PID_BEFORE="$(get_remote_container_pid "${WORKER_IP}" dspark-worker)"
  docker_cmd_remote "${WORKER_IP}" stop dspark-worker || true
  docker_cmd_remote "${WORKER_IP}" rm -f dspark-worker || true
  if timeout "${STOP_TIMEOUT_SEC}" "${sshw[@]}" "${SSH_USER}@${WORKER_IP}" "(docker ps --format '{{.Names}}' 2>/dev/null || sudo -n docker ps --format '{{.Names}}' 2>/dev/null) | grep -E '^dspark-worker$' >/dev/null" >/dev/null 2>&1; then
    log "remote: container still running, forcing kill"
    docker_cmd_remote "${WORKER_IP}" kill dspark-worker || true
    hard_kill_remote_pid "${WORKER_IP}" "${REMOTE_PID_BEFORE}"
    docker_cmd_remote "${WORKER_IP}" rm -f dspark-worker || true
  fi
fi

log "== residual check =="
(container_running_local && log 'local: dspark-head still running') || log 'local: dspark-head stopped'
if [ "${REMOTE_UNREACHABLE}" = "1" ]; then
  log "remote: dspark-worker unknown (worker unreachable)"
else
  (timeout "${STOP_TIMEOUT_SEC}" "${sshw[@]}" "${SSH_USER}@${WORKER_IP}" "(docker ps --format '{{.Names}}' 2>/dev/null || sudo -n docker ps --format '{{.Names}}' 2>/dev/null) | grep -E '^dspark-worker$' >/dev/null" >/dev/null 2>&1 \
    && log "remote: dspark-worker still running" \
    || log "remote: dspark-worker stopped")
fi

log "safe-stop complete"

if [ "${REMOTE_UNREACHABLE}" = "1" ] && [ "${FAIL_ON_UNREACHABLE}" = "1" ]; then
  log "safe-stop exit: worker unreachable"
  exit 2
fi
