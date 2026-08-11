#!/usr/bin/env bash
# DeepSeek-V4-Flash-0731 NVFP4-DSpark · Dual DGX Spark Production Orchestrator
#
# "Best of all" script distilled from four community recipes:
#   - tonyd2wild/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark (base + sparkrun)
#   - DeepSeek-V4-Flash-0731-3.23x1M-context-653-toks-2x-DGX-Spark-GB10 (KV pin + cudagraph ladder)
#   - MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark (Anemll prebuilt image)
#   - dgx-spark-2-deepseek-flash-0731 (Chinese guide, Anemll image)
#
# Key lessons baked in:
#   - custom runtime image (vllm-dspark-runtime:dspark-nvfp4-stage-c) with the
#     DSpark spec-decode + B12X MoE kernels baked in
#   - Patch 4 (0004-dspark-shared-expert-gate-up-proj.patch) bind-mounted read-only
#     into the head container so the 0731 weights get correct draft acceptance
#   - same Ray-based 2-node TP=2 bring-up, same IPs/SSH as the Hy3 script
#   - gpu_memory_utilization 0.78 (NOT 0.85 — avoids first-request OOM, issue #8)
#   - max_num_seqs 6 (NOT 12 — 12 is an issue-#8 trigger profile)
#   - --kv-cache-memory-bytes pin (removes non-deterministic GB10 profiler)
#   - explicit cudagraph capture ladder (multiples of 6 for k=5 spec decode)
#
# NOTE on the srivatsa1 "Stage-D" forum experiment: it reported ~3x throughput
# by fixing the DSpark draft quantization path (draft MoE backend must be `b12x`,
# not `flashinfer_b12x`; draft quant metadata normalization). Those fixes are
# image-level (baked into a custom image) and are NOT yet in tonyd's repo. If
# you build your own image, apply them; this script's flags are compatible.
#
# IMPORTANT: this script assumes you have on both nodes:
#   - the runtime image (build with build-dspark-vllm-runtime.sh), OR the
#     Anemll prebuilt image (set IMAGE=ghcr.io/anemll/dspark-vllm-gx10:0.1.1)
#   - the Patch 4 file next to this script
# It does NOT build the image for you.
set -euo pipefail

# ---- Cluster (edit to match your fabric) -----------------------------------
HEAD_IP="192.168.100.10"
WORKER_IP="192.168.100.11"
SSH_KEY="/home/gipsoft/.ssh/id_ed25519_shared"
HS_IFACE="enp1s0f0np0"
RAY_PORT=6379
VLLM_MASTER_PORT="${VLLM_MASTER_PORT:-25000}"
NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-1}"
NCCL_P2P_DISABLE="${NCCL_P2P_DISABLE:-1}"
NCCL_IB_HCA="${NCCL_IB_HCA:-roceP2p1s0f0}"
NCCL_IB_GID_INDEX="${NCCL_IB_GID_INDEX:-0}"
NCCL_CROSS_NIC="${NCCL_CROSS_NIC:-1}"
NCCL_NET="${NCCL_NET:-}"
VLLM_DISABLE_CUSTOM_ALL_REDUCE="${VLLM_DISABLE_CUSTOM_ALL_REDUCE:-1}"
if [ "${NCCL_IB_DISABLE}" = "1" ] && [ -z "${NCCL_NET}" ]; then
  NCCL_NET="Socket"
fi
RAY_RUNTIME_INSTALL="${RAY_RUNTIME_INSTALL:-0}"
VLLM_USE_DEEP_GEMM="${VLLM_USE_DEEP_GEMM:-0}"
VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"
VLLM_USE_B12X_MHC="${VLLM_USE_B12X_MHC:-1}"
VLLM_USE_B12X_FP8_GEMM="${VLLM_USE_B12X_FP8_GEMM:-1}"
VLLM_TEST_FORCE_FP8_MARLIN="${VLLM_TEST_FORCE_FP8_MARLIN:-0}"
VLLM_DISABLED_KERNELS="${VLLM_DISABLED_KERNELS:-CutlassFp8BlockScaledMMKernel,CutlassFP8ScaledMMLinearKernel,TritonFp8BlockScaledMMKernel,DeepGemmFp8BlockScaledMMKernel,FlashInferFp8DeepGEMMDynamicBlockScaledKernel,MarlinFP8ScaledMMLinearKernel}"
B12X_MHC_MAX_TOKENS="${B12X_MHC_MAX_TOKENS:-0}"
FORCE_MHC_TORCH_FALLBACK="${FORCE_MHC_TORCH_FALLBACK:-1}"
FORCE_DSPARK_WO_FALLBACK="${FORCE_DSPARK_WO_FALLBACK:-1}"
FORCE_DISABLE_DEEP_GEMM_MQA_METADATA="${FORCE_DISABLE_DEEP_GEMM_MQA_METADATA:-1}"
FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER="${FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER:-1}"
FORCE_DEEP_GEMM_SM121_COMPAT="${FORCE_DEEP_GEMM_SM121_COMPAT:-1}"
ENABLE_FLASHINFER_AUTOTUNE="${ENABLE_FLASHINFER_AUTOTUNE:-0}"
ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP="${ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP:-0}"
ENABLE_FIRST_REQUEST_PREWARM="${ENABLE_FIRST_REQUEST_PREWARM:-1}"
ENABLE_EXTENDED_PREWARM="${ENABLE_EXTENDED_PREWARM:-1}"
PREWARM_MAX_TOKENS="${PREWARM_MAX_TOKENS:-32}"
PREWARM_TIMEOUT_SEC="${PREWARM_TIMEOUT_SEC:-300}"
LINEAR_BACKEND="${LINEAR_BACKEND:-auto}"
ENABLE_TORCH_COMPILE="${ENABLE_TORCH_COMPILE:-0}"
C_COMPILER_RUNTIME_INSTALL="${C_COMPILER_RUNTIME_INSTALL:-0}"
WAIT_FOR_HEALTH="${WAIT_FOR_HEALTH:-1}"
STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_SEC:-1800}"
HEALTH_POLL_SEC="${HEALTH_POLL_SEC:-10}"
STOP_CONTAINERS_ON_INTERRUPT="${STOP_CONTAINERS_ON_INTERRUPT:-1}"
INTERRUPT_CLEANUP_TIMEOUT_SEC="${INTERRUPT_CLEANUP_TIMEOUT_SEC:-8}"

# ---- Model / image ----------------------------------------------------------
# The 0731 weights live in the HF cache under this repo id.
DSPARK_MODEL="${DSPARK_MODEL:-deepseek-ai/DeepSeek-V4-Flash-0731}"
HF_HUB_HOST_DIR="/home/gipsoft/.cache/huggingface"
# Container path where the model is found (HF_HOME=/cache/huggingface).
MODEL_CONTAINER_DIR="/cache/huggingface/hub/models--${DSPARK_MODEL/\//--}/snapshots"
PIP_CACHE_HOST_DIR="${PIP_CACHE_HOST_DIR:-/home/gipsoft/.cache/pip}"
PIP_CACHE_CONTAINER_DIR="/root/.cache/pip"

# Runtime image (must be present on both nodes — build with build-dspark-vllm-runtime.sh)
IMAGE="${IMAGE:-vllm-dspark-runtime:dspark-nvfp4-stage-c}"

# Patch 4 — fixes the DSpark draft shared-expert loader for 0731 weights.
# It lives in the repo's patches/ folder (tonyd2wild layout). We look there
# first (repo-root patches/), then fall back to the script directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/../patches/0004-dspark-shared-expert-gate-up-proj.patch" ]; then
  PATCH4_SRC="${SCRIPT_DIR}/../patches/0004-dspark-shared-expert-gate-up-proj.patch"
elif [ -f "${SCRIPT_DIR}/patches/0004-dspark-shared-expert-gate-up-proj.patch" ]; then
  PATCH4_SRC="${SCRIPT_DIR}/patches/0004-dspark-shared-expert-gate-up-proj.patch"
else
  PATCH4_SRC="${SCRIPT_DIR}/0004-dspark-shared-expert-gate-up-proj.patch"
fi
# Container path of the file the patch edits (inside the runtime image).
PATCH4_TARGET="/opt/env/lib/python3.12/site-packages/vllm/v1/spec_decode/dspark.py"
# We bind-mount a patched copy over the original (read-only on the original).
PATCH4_CONTAINER_DIR="/tmp/dspark_patch"
PATCH4_APPLIED="${PATCH4_CONTAINER_DIR}/dspark.py"

# ---- Serving knobs ----------------------------------------------------------
# These defaults are the "current best" profile distilled from multiple
# community recipes (tonyd2wild sparkrun, 3.23x1M, MiaAI-Lab, dgx-spark-2):
#   * gpu_memory_utilization 0.78 (NOT 0.85): 0.85 boots but triggers a
#     first-request OOM on real traffic (upstream issue #8). 0.78 is safe.
#   * max_num_seqs 6 (NOT 12): 12 is a documented issue-#8 trigger profile.
#   * num_speculative_tokens 5: the 0731 drafter emits exactly 5 tokens/pass;
#     k must be 5 (or a multiple of 5). k=7 boots only if you patch the guard
#     and then crashes on first generation.
PORT=8888
MAX_MODEL_LEN="${MAX_MODEL_LEN:-1048576}"   # 1M = true YaRN ceiling
MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-1024}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.78}"
# KV cache pin (from the 3.23x1M recipe). The memory profiler on GB10 is
# non-deterministic across boots; pinning the KV pool makes it a chosen number
# instead of a dice roll. 24 GiB ≈ 3.2M-token pool at nvfp4_ds_mla. Size from
# vLLM's own ValueError ("N GiB KV cache is needed..."), never from arithmetic.
KV_CACHE_MEMORY_BYTES="${KV_CACHE_MEMORY_BYTES:-24000000000}"
MTP_NUM_TOKENS="${MTP_NUM_TOKENS:-5}"        # k=5, garble-safe with probabilistic sampling
SERVED_NAME="${SERVED_NAME:-deepseek-v4-flash-dspark}"
ENABLE_ASYNC_SCHEDULING="${ENABLE_ASYNC_SCHEDULING:-0}"

# Explicit cudagraph capture ladder (from 3.23x1M). With spec k=5 each accepted
# step advances up to k+1=6 tokens, so the default power-of-two ladder has no
# useful multiple where the batch lands. Capture sizes that are multiples of 6
# put decode on graphs instead of eager. This took c=12 from 147 -> 310 tok/s.
CUDA_GRAPH_CAPTURE_SIZES="${CUDA_GRAPH_CAPTURE_SIZES:-2,4,6,12,24,48,72,96,144}"

SERVE_SCRIPT_LOCAL="/tmp/dspark-serve-${PORT}.sh"
SERVE_SCRIPT_IN_CONTAINER="/tmp/dspark-serve.sh"
SERVE_LOG_IN_CONTAINER="/tmp/dspark-serve.log"

docker_common=(
  --network host --ipc host --privileged --security-opt label=disable --gpus all
  --ulimit memlock=-1 --ulimit stack=67108864
  -v "${HF_HUB_HOST_DIR}:/cache/huggingface:ro"
  -v "${PIP_CACHE_HOST_DIR}:${PIP_CACHE_CONTAINER_DIR}"
  --entrypoint /bin/bash
  -e RAY_memory_usage_threshold=0.99 -e RAY_memory_monitor_refresh_ms=0
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID -e CUDA_DEVICE_MAX_CONNECTIONS=32
  -e NCCL_SOCKET_IFNAME="${HS_IFACE}" -e GLOO_SOCKET_IFNAME="${HS_IFACE}"
  -e NCCL_NET="${NCCL_NET}"
  -e NCCL_P2P_DISABLE="${NCCL_P2P_DISABLE}"
  -e NCCL_IB_DISABLE="${NCCL_IB_DISABLE}" -e NCCL_IB_HCA="${NCCL_IB_HCA}"
  -e NCCL_IB_GID_INDEX="${NCCL_IB_GID_INDEX}" -e NCCL_CROSS_NIC="${NCCL_CROSS_NIC}"
  -e NCCL_MAX_NCHANNELS=4 -e NCCL_MIN_NCHANNELS=4
  -e NCCL_ASYNC_ERROR_HANDLING=1 -e TORCH_NCCL_ASYNC_ERROR_HANDLING=1
  -e TORCH_NCCL_BLOCKING_WAIT=1
  # DSpark-specific env (subset that matters for the serve command)
  -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
  -e VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER}"
  -e VLLM_USE_B12X_MHC="${VLLM_USE_B12X_MHC}"
  -e VLLM_USE_B12X_FP8_GEMM="${VLLM_USE_B12X_FP8_GEMM}"
  -e VLLM_TEST_FORCE_FP8_MARLIN="${VLLM_TEST_FORCE_FP8_MARLIN}"
  -e VLLM_DISABLED_KERNELS="${VLLM_DISABLED_KERNELS}"
  -e B12X_MHC_MAX_TOKENS="${B12X_MHC_MAX_TOKENS}"
  -e VLLM_USE_B12X_MOE=1
  -e VLLM_USE_B12X_WO_PROJECTION=1
  -e VLLM_USE_DEEP_GEMM="${VLLM_USE_DEEP_GEMM}"
  -e VLLM_DSPARK_GPU_REJECTED_CONTEXT_MASK=1
  -e VLLM_DSPARK_LOCAL_ARGMAX=1
  -e VLLM_DSPARK_REPLICATE_MARKOV_W1=1
  -e VLLM_DSPARK_FUSED_MARKOV_ARGMAX=0
  -e VLLM_DSPARK_REFERENCE_KV_QUANT_DEQUANT=0
  -e VLLM_DSV4_B12X_COMPRESSED_MLA=0
  -e VLLM_DSV4_DSPARK_DEFER_TARGET_CAPTURE=0
  -e VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP="${ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP}"
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
  -e CC=/usr/bin/gcc -e CXX=/usr/bin/g++
  -e CUDA_HOME=/opt/env
  -e LD_LIBRARY_PATH=/opt/env/lib:/opt/env/targets/sbsa-linux/lib:/usr/local/cuda/lib64
  -e LD_PRELOAD=/opt/env/lib/libnvrtc.so:/opt/env/lib/libnvrtc-builtins.so
  -e HF_HOME=/cache/huggingface
  -e VLLM_CACHE_ROOT=/tmp/vllm-cache
  -e DG_JIT_CACHE_DIR=/tmp/deepgemm-cache
  -e DG_JIT_USE_NVRTC=1
  # Keep compile/runtime caches off the read-only HF mount.
  -e XDG_CACHE_HOME=/tmp/xdg-cache
  -e TILELANG_CACHE_DIR=/tmp/tilelang-cache
  -e TVM_CACHE_DIR=/tmp/tvm-cache
  -e TORCHINDUCTOR_CACHE_DIR=/tmp/torchinductor-cache
  -e TRITON_CACHE_DIR=/tmp/triton-cache
  -e FLASHINFER_WORKSPACE_BASE=/tmp
  -e FLASHINFER_WORKSPACE_DIR=/tmp/flashinfer
)

sshw=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY"
      -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=10)

LAUNCH_IN_PROGRESS=0

cleanup_on_interrupt() {
  local ec=$?
  if [ "${LAUNCH_IN_PROGRESS}" = "1" ] && [ "${STOP_CONTAINERS_ON_INTERRUPT}" = "1" ]; then
    echo ""
    echo "INTERRUPTED: stopping dspark containers on both nodes..."
    timeout "${INTERRUPT_CLEANUP_TIMEOUT_SEC}" docker rm -f dspark-head >/dev/null 2>&1 || true
    timeout "${INTERRUPT_CLEANUP_TIMEOUT_SEC}" \
      "${sshw[@]}" "gipsoft@${WORKER_IP}" \
      "sudo docker rm -f dspark-worker >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    echo "cleanup complete (bounded by ${INTERRUPT_CLEANUP_TIMEOUT_SEC}s per node)"
    echo "If containers persist, run manual stop commands from a fresh shell."
  fi
  exit "${ec}"
}

trap cleanup_on_interrupt INT TERM

echo "== teardown any prior dspark containers =="
docker rm -f dspark-head 2>/dev/null || true
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker rm -f dspark-worker 2>/dev/null || true"
LAUNCH_IN_PROGRESS=1

echo "== config =="
echo "  IMAGE=${IMAGE}"
echo "  DSPARK_MODEL=${DSPARK_MODEL}"
echo "  RAY_PORT=${RAY_PORT}"
echo "  VLLM_MASTER_PORT=${VLLM_MASTER_PORT}"
echo "  RAY_RUNTIME_INSTALL=${RAY_RUNTIME_INSTALL}"
echo "  NCCL_IB_DISABLE=${NCCL_IB_DISABLE}"
echo "  NCCL_P2P_DISABLE=${NCCL_P2P_DISABLE}"
echo "  NCCL_IB_HCA=${NCCL_IB_HCA}"
echo "  NCCL_IB_GID_INDEX=${NCCL_IB_GID_INDEX}"
echo "  NCCL_NET=${NCCL_NET}"
echo "  VLLM_DISABLE_CUSTOM_ALL_REDUCE=${VLLM_DISABLE_CUSTOM_ALL_REDUCE}"
echo "  VLLM_USE_DEEP_GEMM=${VLLM_USE_DEEP_GEMM}"
echo "  VLLM_USE_FLASHINFER_SAMPLER=${VLLM_USE_FLASHINFER_SAMPLER}"
echo "  VLLM_USE_B12X_MHC=${VLLM_USE_B12X_MHC}"
echo "  VLLM_USE_B12X_FP8_GEMM=${VLLM_USE_B12X_FP8_GEMM}"
echo "  VLLM_TEST_FORCE_FP8_MARLIN=${VLLM_TEST_FORCE_FP8_MARLIN}"
echo "  VLLM_DISABLED_KERNELS=${VLLM_DISABLED_KERNELS}"
echo "  B12X_MHC_MAX_TOKENS=${B12X_MHC_MAX_TOKENS}"
echo "  FORCE_MHC_TORCH_FALLBACK=${FORCE_MHC_TORCH_FALLBACK}"
echo "  FORCE_DSPARK_WO_FALLBACK=${FORCE_DSPARK_WO_FALLBACK}"
echo "  FORCE_DISABLE_DEEP_GEMM_MQA_METADATA=${FORCE_DISABLE_DEEP_GEMM_MQA_METADATA}"
echo "  FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER=${FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER}"
echo "  FORCE_DEEP_GEMM_SM121_COMPAT=${FORCE_DEEP_GEMM_SM121_COMPAT}"
echo "  ENABLE_FLASHINFER_AUTOTUNE=${ENABLE_FLASHINFER_AUTOTUNE}"
echo "  ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP=${ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP}"
echo "  ENABLE_FIRST_REQUEST_PREWARM=${ENABLE_FIRST_REQUEST_PREWARM}"
echo "  ENABLE_EXTENDED_PREWARM=${ENABLE_EXTENDED_PREWARM}"
echo "  PREWARM_MAX_TOKENS=${PREWARM_MAX_TOKENS}"
echo "  PREWARM_TIMEOUT_SEC=${PREWARM_TIMEOUT_SEC}"
echo "  LINEAR_BACKEND=${LINEAR_BACKEND}"
echo "  ENABLE_TORCH_COMPILE=${ENABLE_TORCH_COMPILE}"
echo "  C_COMPILER_RUNTIME_INSTALL=${C_COMPILER_RUNTIME_INSTALL}"
echo "  WAIT_FOR_HEALTH=${WAIT_FOR_HEALTH}"
echo "  STARTUP_TIMEOUT_SEC=${STARTUP_TIMEOUT_SEC}"
echo "  MAX_MODEL_LEN=${MAX_MODEL_LEN}"
echo "  MAX_NUM_SEQS=${MAX_NUM_SEQS}"
echo "  MAX_NUM_BATCHED_TOKENS=${MAX_NUM_BATCHED_TOKENS}"
echo "  ENABLE_ASYNC_SCHEDULING=${ENABLE_ASYNC_SCHEDULING}"
echo "  MTP_NUM_TOKENS=${MTP_NUM_TOKENS}"

# Verify Patch 4 exists
if [ ! -f "${PATCH4_SRC}" ]; then
  echo "ERROR: Patch 4 not found at ${PATCH4_SRC}"
  echo "Download it from the DeepSeek-v4-Flash-0731 repo (patches/0004-dspark-shared-expert-gate-up-proj.patch)."
  exit 1
fi

echo "== start Ray head (Bluey) =="
docker run -d --name dspark-head "${docker_common[@]}" \
  -e VLLM_HOST_IP="${HEAD_IP}" "${IMAGE}" \
  -c "sleep infinity"

echo "== start Ray worker (Reddie) =="
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker run -d \
  --name dspark-worker \
  --network host --ipc host --privileged --security-opt label=disable --gpus all \
  --entrypoint /bin/bash \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -v ${HF_HUB_HOST_DIR}:/cache/huggingface:ro \
  -v ${PIP_CACHE_HOST_DIR}:${PIP_CACHE_CONTAINER_DIR} \
  -e RAY_memory_usage_threshold=0.99 -e RAY_memory_monitor_refresh_ms=0 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID -e CUDA_DEVICE_MAX_CONNECTIONS=32 \
  -e NCCL_SOCKET_IFNAME=${HS_IFACE} -e GLOO_SOCKET_IFNAME=${HS_IFACE} \
  -e NCCL_NET=${NCCL_NET} \
  -e NCCL_P2P_DISABLE=${NCCL_P2P_DISABLE} \
  -e NCCL_IB_DISABLE=${NCCL_IB_DISABLE} -e NCCL_IB_HCA=${NCCL_IB_HCA} \
  -e NCCL_IB_GID_INDEX=${NCCL_IB_GID_INDEX} -e NCCL_CROSS_NIC=${NCCL_CROSS_NIC} \
  -e NCCL_MAX_NCHANNELS=4 -e NCCL_MIN_NCHANNELS=4 \
  -e NCCL_ASYNC_ERROR_HANDLING=1 -e TORCH_NCCL_ASYNC_ERROR_HANDLING=1 \
  -e TORCH_NCCL_BLOCKING_WAIT=1 \
  -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
  -e VLLM_USE_FLASHINFER_SAMPLER=${VLLM_USE_FLASHINFER_SAMPLER} \
  -e VLLM_USE_B12X_MHC=${VLLM_USE_B12X_MHC} \
  -e VLLM_USE_B12X_FP8_GEMM=${VLLM_USE_B12X_FP8_GEMM} \
  -e VLLM_TEST_FORCE_FP8_MARLIN=${VLLM_TEST_FORCE_FP8_MARLIN} \
  -e VLLM_DISABLED_KERNELS=${VLLM_DISABLED_KERNELS} \
  -e B12X_MHC_MAX_TOKENS=${B12X_MHC_MAX_TOKENS} \
  -e VLLM_USE_B12X_MOE=1 -e VLLM_USE_B12X_WO_PROJECTION=1 \
  -e VLLM_USE_DEEP_GEMM=${VLLM_USE_DEEP_GEMM} \
  -e VLLM_DSPARK_GPU_REJECTED_CONTEXT_MASK=1 \
  -e VLLM_DSPARK_LOCAL_ARGMAX=1 -e VLLM_DSPARK_REPLICATE_MARKOV_W1=1 \
  -e VLLM_DSPARK_FUSED_MARKOV_ARGMAX=0 -e VLLM_DSPARK_REFERENCE_KV_QUANT_DEQUANT=0 \
  -e VLLM_DSV4_B12X_COMPRESSED_MLA=0 -e VLLM_DSV4_DSPARK_DEFER_TARGET_CAPTURE=0 \
  -e VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP=${ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP} \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e CC=/usr/bin/gcc -e CXX=/usr/bin/g++ \
  -e CUDA_HOME=/opt/env \
  -e LD_LIBRARY_PATH=/opt/env/lib:/opt/env/targets/sbsa-linux/lib:/usr/local/cuda/lib64 \
  -e LD_PRELOAD=/opt/env/lib/libnvrtc.so:/opt/env/lib/libnvrtc-builtins.so \
  -e HF_HOME=/cache/huggingface \
  -e VLLM_CACHE_ROOT=/tmp/vllm-cache \
  -e DG_JIT_CACHE_DIR=/tmp/deepgemm-cache \
  -e DG_JIT_USE_NVRTC=1 \
  -e XDG_CACHE_HOME=/tmp/xdg-cache \
  -e TILELANG_CACHE_DIR=/tmp/tilelang-cache \
  -e TVM_CACHE_DIR=/tmp/tvm-cache \
  -e TORCHINDUCTOR_CACHE_DIR=/tmp/torchinductor-cache \
  -e TRITON_CACHE_DIR=/tmp/triton-cache \
  -e FLASHINFER_WORKSPACE_BASE=/tmp \
  -e FLASHINFER_WORKSPACE_DIR=/tmp/flashinfer \
  -e VLLM_HOST_IP=${WORKER_IP} ${IMAGE} \
  -c 'sleep infinity'"

echo "== start Ray on head + worker =="
if ! docker exec -i dspark-head python3 -c "import ray" >/dev/null 2>&1; then
  if [ "${RAY_RUNTIME_INSTALL}" = "1" ]; then
    docker exec -i dspark-head python3 -m pip install "ray[default]"
  else
    echo "ERROR: ray not found in dspark-head image and RAY_RUNTIME_INSTALL=0"
    echo "Rebuild image with recipe/nvfp4/Dockerfile.stage-c or rerun with RAY_RUNTIME_INSTALL=1"
    exit 1
  fi
fi
if ! "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec -i dspark-worker python3 -c 'import ray'" >/dev/null 2>&1; then
  if [ "${RAY_RUNTIME_INSTALL}" = "1" ]; then
    "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec -i dspark-worker python3 -m pip install 'ray[default]'"
  else
    echo "ERROR: ray not found in dspark-worker image and RAY_RUNTIME_INSTALL=0"
    echo "Rebuild image with recipe/nvfp4/Dockerfile.stage-c or rerun with RAY_RUNTIME_INSTALL=1"
    exit 1
  fi
fi
docker exec -d dspark-head /opt/env/bin/ray start --head --node-ip-address="${HEAD_IP}" --port="${RAY_PORT}" --disable-usage-stats --block || true
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec -d dspark-worker /opt/env/bin/ray start --address=${HEAD_IP}:${RAY_PORT} --node-ip-address=${WORKER_IP} --disable-usage-stats --block" || true

echo "== wait for 2 ray nodes =="
for i in $(seq 1 30); do
  N=$(docker exec dspark-head bash -lc "/opt/env/bin/ray list nodes --format json 2>/dev/null | grep -o '\"state\"[[:space:]]*:[[:space:]]*\"ALIVE\"' | wc -l || true")
  if [ "${N}" -eq 0 ]; then
    N=$(docker exec dspark-head /opt/env/bin/ray status 2>/dev/null | grep -c "node_" || true)
  fi
  echo "  ray nodes: $N"
  if [ "$N" -ge 2 ]; then
    break
  fi
  sleep 5
done

N=$(docker exec dspark-head bash -lc "/opt/env/bin/ray list nodes --format json 2>/dev/null | grep -o '\"state\"[[:space:]]*:[[:space:]]*\"ALIVE\"' | wc -l || true")
if [ "${N}" -eq 0 ]; then
  N=$(docker exec dspark-head /opt/env/bin/ray status 2>/dev/null | grep -c "node_" || true)
fi
if [ "$N" -lt 2 ]; then
  echo "ERROR: Ray cluster did not reach 2 nodes (got $N)."
  echo "Check worker host reachability and docker on ${WORKER_IP}."
  exit 1
fi

echo "== preflight: ensure C compiler for Triton JIT =="
if ! docker exec dspark-head bash -lc "command -v cc >/dev/null || command -v gcc >/dev/null || command -v clang >/dev/null"; then
  if [ "${C_COMPILER_RUNTIME_INSTALL}" = "1" ]; then
    docker exec dspark-head bash -lc "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends gcc g++ libc6-dev ninja-build && ln -sf /usr/bin/gcc /usr/bin/cc"
  else
    echo "ERROR: no C compiler found in dspark-head container."
    echo "Set C_COMPILER_RUNTIME_INSTALL=1 for a one-shot apt install, or rebuild the image with gcc preinstalled."
    exit 1
  fi
fi

if ! docker exec dspark-head bash -lc "command -v ninja >/dev/null"; then
  if [ "${C_COMPILER_RUNTIME_INSTALL}" = "1" ]; then
    docker exec dspark-head bash -lc "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends ninja-build"
  else
    echo "ERROR: ninja not found in dspark-head container."
    echo "Rebuild the stage-c image with ninja-build baked in."
    exit 1
  fi
fi

if ! "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'command -v cc >/dev/null || command -v gcc >/dev/null || command -v clang >/dev/null'"; then
  if [ "${C_COMPILER_RUNTIME_INSTALL}" = "1" ]; then
    "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends gcc g++ libc6-dev ninja-build && ln -sf /usr/bin/gcc /usr/bin/cc'"
  else
    echo "ERROR: no C compiler found in dspark-worker container."
    echo "Set C_COMPILER_RUNTIME_INSTALL=1 for a one-shot apt install, or rebuild the image with gcc preinstalled."
    exit 1
  fi
fi

if ! "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'command -v ninja >/dev/null'"; then
  if [ "${C_COMPILER_RUNTIME_INSTALL}" = "1" ]; then
    "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends ninja-build'"
  else
    echo "ERROR: ninja not found in dspark-worker container."
    echo "Rebuild the stage-c image with ninja-build baked in."
    exit 1
  fi
fi

echo "== preflight: verify model files in both containers =="
docker exec dspark-head test -d "${MODEL_CONTAINER_DIR}"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker test -d ${MODEL_CONTAINER_DIR}"

echo "== apply Patch 4 (bind-mount patched dspark.py into head) =="
# Copy the original out of the image, apply the patch, and bind-mount it back.
docker run --rm --entrypoint bash "${IMAGE}" -c \
  "cp ${PATCH4_TARGET} /tmp/dspark_orig.py" 2>/dev/null || true
# Simpler: extract, patch on host, mount back.
TMP_PATCH_DIR="$(mktemp -d)"
docker create --name dspark_extract "${IMAGE}" 2>/dev/null
docker cp "dspark_extract:${PATCH4_TARGET}" "${TMP_PATCH_DIR}/dspark.py"
docker rm -f dspark_extract >/dev/null 2>&1
# Apply Patch 4 non-interactively. The patch paths are typically
# a/vllm/v1/spec_decode/dspark.py, while our extracted file is dspark.py.
# Try both common strip levels and continue with original on failure.
if patch --dry-run --batch --forward -p1 -d "${TMP_PATCH_DIR}" < "${PATCH4_SRC}" >/dev/null 2>&1; then
  patch --batch --forward -p1 -d "${TMP_PATCH_DIR}" < "${PATCH4_SRC}" >/dev/null
  echo "Patch 4 applied with -p1"
elif patch --dry-run --batch --forward -p4 -d "${TMP_PATCH_DIR}" < "${PATCH4_SRC}" >/dev/null 2>&1; then
  patch --batch --forward -p4 -d "${TMP_PATCH_DIR}" < "${PATCH4_SRC}" >/dev/null
  echo "Patch 4 applied with -p4"
else
  echo "WARNING: Patch 4 did not apply; falling back to original dspark.py"
fi
mkdir -p /tmp/dspark_patch
cp "${TMP_PATCH_DIR}/dspark.py" /tmp/dspark_patch/dspark.py

if [ "${FORCE_MHC_TORCH_FALLBACK}" = "1" ]; then
  echo "== patch MHC CUDA path to torch fallback (avoid tilelang invalid image) =="
  MHC_LAYER_PATH="/opt/env/lib/python3.12/site-packages/vllm/model_executor/layers/mhc.py"
  MHC_TORCH_PATH="/opt/env/lib/python3.12/site-packages/vllm/model_executor/kernels/mhc/torch.py"
  MHC_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${MHC_LAYER_PATH}" "${MHC_TMP_DIR}/mhc.py"
  docker cp "dspark-head:${MHC_TORCH_PATH}" "${MHC_TMP_DIR}/mhc_torch.py"
  sed -i "s/return torch\.ops\.vllm\.mhc_pre_tilelang(/return mhc_kernels.mhc_pre_torch(/" "${MHC_TMP_DIR}/mhc.py"

  # Compatibility shim: mhc_pre_torch in this image takes fewer args than
  # the tilelang callsite passes (norm_weight, norm_eps). Drop extras safely.
  if ! grep -q "MHC_TORCH_FALLBACK_SHIM" "${MHC_TMP_DIR}/mhc_torch.py"; then
    cat >> "${MHC_TMP_DIR}/mhc_torch.py" <<'PYEOF'

# MHC_TORCH_FALLBACK_SHIM
_mhc_pre_torch_orig = mhc_pre_torch


def mhc_pre_torch(*args, **kwargs):
    kwargs.pop("norm_weight", None)
    kwargs.pop("norm_eps", None)
    if len(args) > 10:
        args = args[:10]
    return _mhc_pre_torch_orig(*args, **kwargs)
PYEOF
  fi

  docker cp "${MHC_TMP_DIR}/mhc.py" "dspark-head:${MHC_LAYER_PATH}"
  docker cp "${MHC_TMP_DIR}/mhc_torch.py" "dspark-head:${MHC_TORCH_PATH}"

  cat "${MHC_TMP_DIR}/mhc.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/mhc.py"
  cat "${MHC_TMP_DIR}/mhc_torch.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/mhc_torch.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/mhc.py dspark-worker:${MHC_LAYER_PATH}"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/mhc_torch.py dspark-worker:${MHC_TORCH_PATH}"

  rm -rf "${MHC_TMP_DIR}"
fi

if [ "${FORCE_DSPARK_WO_FALLBACK}" = "1" ]; then
  echo "== patch DSpark WO projection to reference einsum (avoid DeepGEMM fp8_einsum assert) =="
  DSPARK_MODEL_PATH="/opt/env/lib/python3.12/site-packages/vllm/models/deepseek_v4/nvidia/dspark.py"
  DSPARK_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${DSPARK_MODEL_PATH}" "${DSPARK_TMP_DIR}/dspark_model.py"
  python3 - "${DSPARK_TMP_DIR}/dspark_model.py" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

fallback_import = "from vllm.v1.attention.ops.rocm_aiter_mla_sparse import rocm_inv_rope_einsum\n"
if fallback_import not in text:
    anchor = "from vllm.platforms import current_platform\n"
    if anchor not in text:
        raise SystemExit("ERROR: dspark model import anchor not found")
    text = text.replace(anchor, anchor + fallback_import, 1)

if "DSPARK_WO_EINSUM_FALLBACK_SHIM" not in text:
    pattern = re.compile(
        r"^[ \t]*out_fp8, out_scale = fused_inv_rope_fp8_quant\(\n"
        r"(?:.*\n)*?"
        r"^[ \t]*return _linear_no_bias\(self\.wo_b, projected\.flatten\(1\)\.to\(self\.dtype\)\)\n",
        flags=re.MULTILINE,
    )
    replacement = (
        "        # DSPARK_WO_EINSUM_FALLBACK_SHIM\n"
        "        projected = rocm_inv_rope_einsum(\n"
        "            self.rotary_emb,\n"
        "            out,\n"
        "            positions,\n"
        "            self.rope_head_dim,\n"
        "            self.n_local_groups,\n"
        "            self.o_lora_rank,\n"
        "            self.wo_a,\n"
        "        )\n"
        "        return _linear_no_bias(self.wo_b, projected.flatten(1).to(self.dtype))\n"
    )
    text, n = pattern.subn(replacement, text, count=1)
    if n != 1:
        raise SystemExit("ERROR: dspark model WO fp8_einsum block not found for replacement")

path.write_text(text)
PY
  grep -q "DSPARK_WO_EINSUM_FALLBACK_SHIM" "${DSPARK_TMP_DIR}/dspark_model.py"

  docker cp "${DSPARK_TMP_DIR}/dspark_model.py" "dspark-head:${DSPARK_MODEL_PATH}"

  cat "${DSPARK_TMP_DIR}/dspark_model.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/dspark_model.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/dspark_model.py dspark-worker:${DSPARK_MODEL_PATH}"

  rm -rf "${DSPARK_TMP_DIR}"
fi

if [ "${FORCE_DISABLE_DEEP_GEMM_MQA_METADATA}" = "1" ]; then
  echo "== patch MLA indexer to honor VLLM_USE_DEEP_GEMM for DeepGEMM metadata =="
  MLA_INDEXER_PATH="/opt/env/lib/python3.12/site-packages/vllm/v1/attention/backends/mla/indexer.py"
  MLA_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${MLA_INDEXER_PATH}" "${MLA_TMP_DIR}/indexer.py"
  sed -i "s/if current_platform\.is_cuda() and has_deep_gemm():/if current_platform.is_cuda() and envs.VLLM_USE_DEEP_GEMM and has_deep_gemm():/" "${MLA_TMP_DIR}/indexer.py"
  if ! grep -q "envs.VLLM_USE_DEEP_GEMM and has_deep_gemm()" "${MLA_TMP_DIR}/indexer.py"; then
    echo "ERROR: failed to patch MLA indexer DeepGEMM metadata gate"
    exit 1
  fi

  docker cp "${MLA_TMP_DIR}/indexer.py" "dspark-head:${MLA_INDEXER_PATH}"
  cat "${MLA_TMP_DIR}/indexer.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/indexer.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/indexer.py dspark-worker:${MLA_INDEXER_PATH}"

  rm -rf "${MLA_TMP_DIR}"
fi

if [ "${FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER}" = "1" ]; then
  echo "== patch sparse indexer to avoid DeepGEMM kernels when VLLM_USE_DEEP_GEMM=0 =="
  SPARSE_INDEXER_PATH="/opt/env/lib/python3.12/site-packages/vllm/model_executor/layers/sparse_attn_indexer.py"
  SPARSE_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${SPARSE_INDEXER_PATH}" "${SPARSE_TMP_DIR}/sparse_attn_indexer.py"
  python3 - "${SPARSE_TMP_DIR}/sparse_attn_indexer.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

import_anchor = "from vllm.v1.attention.ops.common import pack_seq_triton, unpack_seq_triton\n"
fallback_import = (
  "from vllm.v1.attention.ops.rocm_aiter_mla_sparse import (\n"
  "    fp8_mqa_logits_torch,\n"
  "    fp8_paged_mqa_logits_torch,\n"
  ")\n"
)
if fallback_import not in text:
  if import_anchor not in text:
    raise SystemExit("ERROR: sparse indexer import anchor not found")
  text = text.replace(import_anchor, import_anchor + fallback_import, 1)

shim_marker = "# SPARSE_INDEXER_DEEP_GEMM_DISABLE_SHIM"
if shim_marker not in text:
  shim_code = '''\n\n# SPARSE_INDEXER_DEEP_GEMM_DISABLE_SHIM
_fp8_fp4_mqa_logits_orig = fp8_fp4_mqa_logits
_fp8_fp4_paged_mqa_logits_orig = fp8_fp4_paged_mqa_logits


def fp8_fp4_mqa_logits(
  q: tuple[torch.Tensor, torch.Tensor | None],
  kv: tuple[torch.Tensor, torch.Tensor],
  weights: torch.Tensor,
  cu_seqlen_ks: torch.Tensor,
  cu_seqlen_ke: torch.Tensor,
  clean_logits: bool = False,
) -> torch.Tensor:
  if current_platform.is_cuda() and not envs.VLLM_USE_DEEP_GEMM:
    q_values, q_scale = q
    if q_scale is not None:
      raise RuntimeError("CUDA torch sparse-indexer fallback does not support FP4 Q")
    k_values, k_scale = kv
    q_fp8 = (
      q_values.view(torch.float8_e4m3fn)
      if q_values.dtype == torch.uint8
      else q_values
    )
    k_fp8 = (
      k_values.view(torch.float8_e4m3fn)
      if k_values.dtype == torch.uint8
      else k_values
    )
    return fp8_mqa_logits_torch(
      q_fp8,
      (k_fp8, k_scale),
      weights,
      cu_seqlen_ks,
      cu_seqlen_ke,
    )
  return _fp8_fp4_mqa_logits_orig(
    q,
    kv,
    weights,
    cu_seqlen_ks,
    cu_seqlen_ke,
    clean_logits=clean_logits,
  )


def fp8_fp4_paged_mqa_logits(
  q: tuple[torch.Tensor, torch.Tensor | None],
  kv_cache: torch.Tensor,
  weights: torch.Tensor,
  context_lens: torch.Tensor,
  block_tables: torch.Tensor,
  schedule_metadata: torch.Tensor,
  max_model_len: int,
  clean_logits: bool = False,
) -> torch.Tensor:
  if current_platform.is_cuda() and not envs.VLLM_USE_DEEP_GEMM:
    q_values, q_scale = q
    if q_scale is not None:
      raise RuntimeError("CUDA torch sparse-indexer fallback does not support FP4 Q")
    q_fp8 = (
      q_values.view(torch.float8_e4m3fn)
      if q_values.dtype == torch.uint8
      else q_values
    )
    return fp8_paged_mqa_logits_torch(
      q_fp8,
      kv_cache,
      weights,
      context_lens,
      block_tables,
      max_model_len=max_model_len,
    )
  return _fp8_fp4_paged_mqa_logits_orig(
    q,
    kv_cache,
    weights,
    context_lens,
    block_tables,
    schedule_metadata,
    max_model_len=max_model_len,
    clean_logits=clean_logits,
  )
'''
  insert_anchor = "def _b12x_sparse_indexer_requested(enabled: bool | None = None) -> bool:\n"
  if insert_anchor not in text:
    raise SystemExit("ERROR: sparse indexer shim insertion anchor not found")
  text = text.replace(insert_anchor, shim_code + "\n" + insert_anchor, 1)

path.write_text(text)
PY

  grep -q "CUDA torch sparse-indexer fallback does not support FP4 Q" "${SPARSE_TMP_DIR}/sparse_attn_indexer.py"

  docker cp "${SPARSE_TMP_DIR}/sparse_attn_indexer.py" "dspark-head:${SPARSE_INDEXER_PATH}"
  cat "${SPARSE_TMP_DIR}/sparse_attn_indexer.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/sparse_attn_indexer.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/sparse_attn_indexer.py dspark-worker:${SPARSE_INDEXER_PATH}"

  rm -rf "${SPARSE_TMP_DIR}"
fi

if [ "${FORCE_DEEP_GEMM_SM121_COMPAT}" = "1" ]; then
  echo "== patch DeepGEMM SM121 include compatibility links =="
  DG_IMPL_DIR="/opt/env/lib/python3.12/site-packages/vllm/third_party/deep_gemm/include/deep_gemm/impls"
  DG_TMP_DIR="$(mktemp -d)"
  cat > "${DG_TMP_DIR}/deepgemm-sm121-compat.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
DG_IMPL_DIR="/opt/env/lib/python3.12/site-packages/vllm/third_party/deep_gemm/include/deep_gemm/impls"
cd "${DG_IMPL_DIR}"
for base in fp8_mqa_logits fp8_paged_mqa_logits fp4_mqa_logits fp4_paged_mqa_logits; do
  if [ -f "sm120_${base}.cuh" ] && [ ! -e "sm121_${base}.cuh" ]; then
    ln -sf "sm120_${base}.cuh" "sm121_${base}.cuh"
  fi
done
EOS
  chmod +x "${DG_TMP_DIR}/deepgemm-sm121-compat.sh"

  docker cp "${DG_TMP_DIR}/deepgemm-sm121-compat.sh" dspark-head:/tmp/deepgemm-sm121-compat.sh
  docker exec dspark-head bash -lc "bash /tmp/deepgemm-sm121-compat.sh && ls -l ${DG_IMPL_DIR}/sm121_*mqa_logits.cuh"

  cat "${DG_TMP_DIR}/deepgemm-sm121-compat.sh" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/deepgemm-sm121-compat.sh"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/deepgemm-sm121-compat.sh dspark-worker:/tmp/deepgemm-sm121-compat.sh"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc 'bash /tmp/deepgemm-sm121-compat.sh && ls -l ${DG_IMPL_DIR}/sm121_*mqa_logits.cuh'"

  rm -rf "${DG_TMP_DIR}"
fi

echo "== launch vllm serve (detached on worker + head) =="
cat > "${SERVE_SCRIPT_LOCAL}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
NODE_RANK="\${NODE_RANK:-0}"
if [ "\${NODE_RANK}" = "0" ]; then
  LOG_FILE="${SERVE_LOG_IN_CONTAINER}"
  export VLLM_HOST_IP="${HEAD_IP}"
  HEADLESS_FLAGS=()
else
  LOG_FILE="/tmp/dspark-serve-worker.log"
  export VLLM_HOST_IP="${WORKER_IP}"
  # For mp multi-node bring-up, non-zero ranks must be headless followers.
  HEADLESS_FLAGS=(--headless)
fi
exec > "\${LOG_FILE}" 2>&1
export HF_HOME=/cache/huggingface
export XDG_CACHE_HOME=/tmp/xdg-cache
export TILELANG_CACHE_DIR=/tmp/tilelang-cache
export TVM_CACHE_DIR=/tmp/tvm-cache
export TORCHINDUCTOR_CACHE_DIR=/tmp/torchinductor-cache
export TRITON_CACHE_DIR=/tmp/triton-cache
export VLLM_CACHE_ROOT=/tmp/vllm-cache
export DG_JIT_CACHE_DIR=/tmp/deepgemm-cache
export DG_JIT_USE_NVRTC=1
export CUDA_HOME=/opt/env
export LD_LIBRARY_PATH=/opt/env/lib64:/opt/env/lib64/stubs:/opt/env/lib:/opt/env/targets/sbsa-linux/lib:/usr/local/cuda/lib64
if [ -f /opt/env/lib/libnvrtc.so ] && [ -f /opt/env/lib/libnvrtc-builtins.so ]; then
  export LD_PRELOAD=/opt/env/lib/libnvrtc.so:/opt/env/lib/libnvrtc-builtins.so
fi
if [ -x /usr/bin/gcc ]; then
  export CC=/usr/bin/gcc
fi
if [ -x /usr/bin/g++ ]; then
  export CXX=/usr/bin/g++
fi

# FlashInfer JIT hard-codes -L/opt/env/lib64 and -L/opt/env/lib64/stubs.
# Some images ship CUDA libs under /opt/env/lib and stubs under
# /opt/env/targets/sbsa-linux/lib/stubs only, so synthesize compatibility links.
mkdir -p /opt/env/lib64 /opt/env/lib64/stubs
for lib in libcudart.so libcudart.so.13 libcudart.so.13.2.75; do
  if [ -f "/opt/env/lib/\${lib}" ] && [ ! -e "/opt/env/lib64/\${lib}" ]; then
    ln -sf "/opt/env/lib/\${lib}" "/opt/env/lib64/\${lib}"
  fi
done
if [ -f /opt/env/targets/sbsa-linux/lib/stubs/libcuda.so ] && [ ! -e /opt/env/lib64/stubs/libcuda.so ]; then
  ln -sf /opt/env/targets/sbsa-linux/lib/stubs/libcuda.so /opt/env/lib64/stubs/libcuda.so
fi
export FLASHINFER_WORKSPACE_BASE=/tmp
export FLASHINFER_WORKSPACE_DIR=/tmp/flashinfer
export VLLM_USE_B12X_MHC=${VLLM_USE_B12X_MHC}
export VLLM_USE_B12X_FP8_GEMM=${VLLM_USE_B12X_FP8_GEMM}
export VLLM_TEST_FORCE_FP8_MARLIN=${VLLM_TEST_FORCE_FP8_MARLIN}
export VLLM_DISABLED_KERNELS=${VLLM_DISABLED_KERNELS}
export B12X_MHC_MAX_TOKENS=${B12X_MHC_MAX_TOKENS}
export VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP=${ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP}

if [ "${ENABLE_FLASHINFER_AUTOTUNE:-0}" = "1" ]; then
  KERNEL_TUNE_FLAGS=(--enable-flashinfer-autotune)
else
  KERNEL_TUNE_FLAGS=(--kernel-config '{"enable_flashinfer_autotune":false}')
fi

mkdir -p \
  /tmp/xdg-cache \
  /tmp/tilelang-cache \
  /tmp/tvm-cache \
  /tmp/torchinductor-cache \
  /tmp/triton-cache \
  /tmp/vllm-cache \
  /tmp/deepgemm-cache \
  /tmp/flashinfer

SPECULATIVE_CONFIG='{"method":"dspark","num_speculative_tokens":${MTP_NUM_TOKENS},"draft_sample_method":"probabilistic"}'
ASYNC_SCHEDULING_FLAGS=()
if [ "${ENABLE_ASYNC_SCHEDULING}" = "1" ]; then
  ASYNC_SCHEDULING_FLAGS=(--async-scheduling)
fi

EXTRA_FLAGS=(--enforce-eager)
if [ "${ENABLE_TORCH_COMPILE:-0}" = "1" ]; then
  EXTRA_FLAGS=(
    --compilation-config '{"cudagraph_capture_sizes":[${CUDA_GRAPH_CAPTURE_SIZES}],"max_cudagraph_capture_size":144}'
  )
fi

CUSTOM_ALL_REDUCE_FLAGS=()
if [ "${VLLM_DISABLE_CUSTOM_ALL_REDUCE}" = "1" ]; then
  CUSTOM_ALL_REDUCE_FLAGS=(--disable-custom-all-reduce)
fi

exec /opt/env/bin/vllm serve "${DSPARK_MODEL}" \
  --served-model-name ${SERVED_NAME} \
  --port ${PORT} \
  --host 0.0.0.0 \
  --linear-backend ${LINEAR_BACKEND} \
  --trust-remote-code \
  --tensor-parallel-size 2 \
  --pipeline-parallel-size 1 \
  --kv-cache-dtype nvfp4_ds_mla \
  --block-size 256 \
  --max-model-len ${MAX_MODEL_LEN} \
  --max-num-seqs ${MAX_NUM_SEQS} \
  --max-num-batched-tokens ${MAX_NUM_BATCHED_TOKENS} \
  --kv-cache-memory-bytes ${KV_CACHE_MEMORY_BYTES} \
  --gpu-memory-utilization ${GPU_MEM_UTIL} \
  --enable-prefix-caching \
  "\${ASYNC_SCHEDULING_FLAGS[@]}" \
  --enable-chunked-prefill \
  --speculative-config "\${SPECULATIVE_CONFIG}" \
  --tokenizer-mode deepseek_v4 \
  --distributed-executor-backend mp \
  --tool-call-parser deepseek_v4 \
  --enable-auto-tool-choice \
  "\${KERNEL_TUNE_FLAGS[@]}" \
  --reasoning-parser deepseek_v4 \
  --reasoning-config '{"reasoning_parser":"deepseek_v4","reasoning_start_str":"<think>","reasoning_end_str":"</think>"}' \
  --default-chat-template-kwargs '{"thinking":false}' \
  --generation-config vllm \
  "\${CUSTOM_ALL_REDUCE_FLAGS[@]}" \
  "\${EXTRA_FLAGS[@]}" \
  "\${HEADLESS_FLAGS[@]}" \
  --nnodes 2 \
  --node-rank \${NODE_RANK} \
  --master-addr ${HEAD_IP} \
  --master-port ${VLLM_MASTER_PORT}
EOF
chmod +x "${SERVE_SCRIPT_LOCAL}"
docker cp "${SERVE_SCRIPT_LOCAL}" "dspark-head:${SERVE_SCRIPT_IN_CONTAINER}"
cat "${SERVE_SCRIPT_LOCAL}" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/dspark-serve.sh"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker cp /tmp/dspark-serve.sh dspark-worker:${SERVE_SCRIPT_IN_CONTAINER}"
# Bind-mount the patched dspark.py over the original in the head container.
docker exec -d dspark-head bash -c "
  mkdir -p ${PATCH4_CONTAINER_DIR} && cp ${PATCH4_TARGET} ${PATCH4_CONTAINER_DIR}/dspark_orig.py
"
# We cannot remount a running container's file; instead, copy the patched file in.
docker cp /tmp/dspark_patch/dspark.py "dspark-head:${PATCH4_TARGET}"
cat /tmp/dspark_patch/dspark.py | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/dspark.py"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker cp /tmp/dspark.py dspark-worker:${PATCH4_TARGET}"
# Start worker rank first so rank 0 can rendezvous immediately.
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec -d dspark-worker bash -lc 'NODE_RANK=1 bash ${SERVE_SCRIPT_IN_CONTAINER}'"
docker exec -d dspark-head bash -lc "NODE_RANK=0 bash ${SERVE_SCRIPT_IN_CONTAINER}"
rm -f "${SERVE_SCRIPT_LOCAL}"

echo "LAUNCHED — Monitor progress using command below:"
echo "docker exec dspark-head tail -f ${SERVE_LOG_IN_CONTAINER}"

if [ "${WAIT_FOR_HEALTH}" = "1" ]; then
  echo "== wait for API health (timeout ${STARTUP_TIMEOUT_SEC}s) =="
  START_TS="$(date +%s)"
  while true; do
    if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      echo "READY: vLLM API is healthy on :${PORT}"
      break
    fi

    NOW_TS="$(date +%s)"
    ELAPSED="$((NOW_TS - START_TS))"
    if [ "${ELAPSED}" -ge "${STARTUP_TIMEOUT_SEC}" ]; then
      echo "ERROR: vLLM health did not become ready within ${STARTUP_TIMEOUT_SEC}s"
      echo "--- head log tail ---"
      docker exec dspark-head bash -lc "tail -n 120 ${SERVE_LOG_IN_CONTAINER}" || true
      echo "--- worker log tail ---"
      "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'tail -n 120 /tmp/dspark-serve-worker.log'" || true
      exit 1
    fi

    echo "  waiting... ${ELAPSED}s"
    sleep "${HEALTH_POLL_SEC}"
  done
fi

if [ "${ENABLE_FIRST_REQUEST_PREWARM}" = "1" ]; then
  echo "== prewarm first inference path (max_tokens=${PREWARM_MAX_TOKENS}) =="
  PREWARM_PAYLOAD=$(cat <<JSON
{"model":"${SERVED_NAME}","messages":[{"role":"user","content":"warmup"}],"max_tokens":${PREWARM_MAX_TOKENS},"temperature":0.0,"stream":false}
JSON
)
  if curl -fsS --max-time "${PREWARM_TIMEOUT_SEC}" \
    -H "Content-Type: application/json" \
    -d "${PREWARM_PAYLOAD}" \
    "http://127.0.0.1:${PORT}/v1/chat/completions" >/tmp/dspark-prewarm.json; then
    echo "PREWARM_DONE: first-request kernels compiled"
  else
    echo "WARNING: prewarm request failed or timed out; first live request may still incur JIT latency"
  fi

  if [ "${ENABLE_EXTENDED_PREWARM}" = "1" ]; then
    echo "== extended prewarm (sampling + chunked prefill) =="
    PREWARM_PAYLOAD_SAMPLING=$(cat <<JSON
{"model":"${SERVED_NAME}","messages":[{"role":"user","content":"warmup sampling path"}],"max_tokens":64,"temperature":0.8,"top_p":0.95,"stream":false}
JSON
)
    curl -fsS --max-time "${PREWARM_TIMEOUT_SEC}" \
      -H "Content-Type: application/json" \
      -d "${PREWARM_PAYLOAD_SAMPLING}" \
      "http://127.0.0.1:${PORT}/v1/chat/completions" >/tmp/dspark-prewarm-sampling.json || true

    PREWARM_PAYLOAD_PREFILL=$(cat <<JSON
{"model":"${SERVED_NAME}","messages":[{"role":"user","content":"warmup prefill $(printf 'token %.0s' {1..1024})"}],"max_tokens":16,"temperature":0.0,"stream":false}
JSON
)
    curl -fsS --max-time "${PREWARM_TIMEOUT_SEC}" \
      -H "Content-Type: application/json" \
      -d "${PREWARM_PAYLOAD_PREFILL}" \
      "http://127.0.0.1:${PORT}/v1/chat/completions" >/tmp/dspark-prewarm-prefill.json || true
    echo "PREWARM_DONE: extended prewarm completed"
  fi
fi

LAUNCH_IN_PROGRESS=0
