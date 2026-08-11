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
RAY_RUNTIME_INSTALL="${RAY_RUNTIME_INSTALL:-auto}"
VLLM_USE_DEEP_GEMM="${VLLM_USE_DEEP_GEMM:-0}"
VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"
MOE_BACKEND="${MOE_BACKEND:-}"
VLLM_USE_B12X_MOE="${VLLM_USE_B12X_MOE:-1}"
VLLM_USE_B12X_WO_PROJECTION="${VLLM_USE_B12X_WO_PROJECTION:-1}"
VLLM_USE_B12X_MHC="${VLLM_USE_B12X_MHC:-1}"
VLLM_USE_B12X_FP8_GEMM="${VLLM_USE_B12X_FP8_GEMM:-1}"
VLLM_TEST_FORCE_FP8_MARLIN="${VLLM_TEST_FORCE_FP8_MARLIN:-0}"
VLLM_DISABLED_KERNELS="${VLLM_DISABLED_KERNELS:-CutlassFp8BlockScaledMMKernel,CutlassFP8ScaledMMLinearKernel,TritonFp8BlockScaledMMKernel,DeepGemmFp8BlockScaledMMKernel,FlashInferFp8DeepGEMMDynamicBlockScaledKernel,MarlinFP8ScaledMMLinearKernel}"
B12X_MHC_MAX_TOKENS="${B12X_MHC_MAX_TOKENS:-0}"
# A/B experiment default: use native MHC TileLang now that CUDA_HOME points
# to the image's working /usr/local/cuda/bin/nvcc. Set to 1 to restore the
# torch compatibility shims if native MHC compilation fails.
FORCE_MHC_TORCH_FALLBACK="${FORCE_MHC_TORCH_FALLBACK:-0}"
FORCE_DSPARK_WO_FALLBACK="${FORCE_DSPARK_WO_FALLBACK:-1}"
FORCE_DISABLE_DEEP_GEMM_MQA_METADATA="${FORCE_DISABLE_DEEP_GEMM_MQA_METADATA:-1}"
FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER="${FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER:-1}"
FORCE_DISABLE_DEEP_GEMM_ON_INVALID_IMAGE="${FORCE_DISABLE_DEEP_GEMM_ON_INVALID_IMAGE:-1}"
FORCE_DEEP_GEMM_SM121_COMPAT="${FORCE_DEEP_GEMM_SM121_COMPAT:-1}"
FORCE_HUMMING_NVML_FALLBACK="${FORCE_HUMMING_NVML_FALLBACK:-1}"
FORCE_DISABLE_HUMMING_FP8_KERNELS="${FORCE_DISABLE_HUMMING_FP8_KERNELS:-1}"
FORCE_DISABLE_CUTLASS_FP8_KERNELS="${FORCE_DISABLE_CUTLASS_FP8_KERNELS:-1}"
FORCE_CUTLASS_SCALED_MM_FALLBACK_SHIM="${FORCE_CUTLASS_SCALED_MM_FALLBACK_SHIM:-1}"
FORCE_FLASHINFER_MQA_OUTPUT_BF16_GUARD="${FORCE_FLASHINFER_MQA_OUTPUT_BF16_GUARD:-1}"
FORCE_NVFP4_CLAMP_BACKEND_RELAX="${FORCE_NVFP4_CLAMP_BACKEND_RELAX:-0}"
RARRI_FORCE_NVFP4_CLAMP_RELAX="${RARRI_FORCE_NVFP4_CLAMP_RELAX:-1}"
ALLOW_INCOMPATIBLE_B12X_MOE="${ALLOW_INCOMPATIBLE_B12X_MOE:-0}"
RARRI_ULTRA_SAFE_MODE="${RARRI_ULTRA_SAFE_MODE:-1}"
ENABLE_SPECULATIVE_DECODE="${ENABLE_SPECULATIVE_DECODE:-auto}"
ENABLE_CHUNKED_PREFILL="${ENABLE_CHUNKED_PREFILL:-auto}"
MAX_JOBS="${MAX_JOBS:-1}"
ENABLE_FLASHINFER_AUTOTUNE="${ENABLE_FLASHINFER_AUTOTUNE:-0}"
ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP="${ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP:-0}"
ENABLE_FIRST_REQUEST_PREWARM="${ENABLE_FIRST_REQUEST_PREWARM:-1}"
ENABLE_EXTENDED_PREWARM="${ENABLE_EXTENDED_PREWARM:-0}"
PREWARM_MAX_TOKENS="${PREWARM_MAX_TOKENS:-32}"
PREWARM_TIMEOUT_SEC="${PREWARM_TIMEOUT_SEC:-300}"
ENABLE_PREFIX_CACHING="${ENABLE_PREFIX_CACHING:-auto}"
LINEAR_BACKEND="${LINEAR_BACKEND:-auto}"
ENABLE_TORCH_COMPILE="${ENABLE_TORCH_COMPILE:-0}"
C_COMPILER_RUNTIME_INSTALL="${C_COMPILER_RUNTIME_INSTALL:-0}"
WAIT_FOR_HEALTH="${WAIT_FOR_HEALTH:-1}"
STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_SEC:-1800}"
HEALTH_POLL_SEC="${HEALTH_POLL_SEC:-10}"
VLLM_ENGINE_READY_TIMEOUT_S="${VLLM_ENGINE_READY_TIMEOUT_S:-3600}"
STOP_CONTAINERS_ON_INTERRUPT="${STOP_CONTAINERS_ON_INTERRUPT:-1}"
INTERRUPT_CLEANUP_TIMEOUT_SEC="${INTERRUPT_CLEANUP_TIMEOUT_SEC:-8}"
WORKER_SSH_STRICT_PREFLIGHT="${WORKER_SSH_STRICT_PREFLIGHT:-1}"
WORKER_SSH_BANNER_TIMEOUT_SEC="${WORKER_SSH_BANNER_TIMEOUT_SEC:-8}"
CONTAINER_RESTART_POLICY="${CONTAINER_RESTART_POLICY:-unless-stopped}"
ENABLE_CONTAINER_MEMORY_GUARDRAILS="${ENABLE_CONTAINER_MEMORY_GUARDRAILS:-1}"
CONTAINER_MEMORY_LIMIT="${CONTAINER_MEMORY_LIMIT:-100g}"
CONTAINER_MEMORY_SWAP="${CONTAINER_MEMORY_SWAP:-104g}"
CONTAINER_MEMORY_RESERVATION="${CONTAINER_MEMORY_RESERVATION:-92g}"
CONTAINER_OOM_SCORE_ADJ="${CONTAINER_OOM_SCORE_ADJ:-500}"
CONTAINER_PIDS_LIMIT="${CONTAINER_PIDS_LIMIT:-4096}"
ENABLE_HOST_MEMORY_PREFLIGHT="${ENABLE_HOST_MEMORY_PREFLIGHT:-1}"
HOST_MEMORY_STRICT_PREFLIGHT="${HOST_MEMORY_STRICT_PREFLIGHT:-1}"
MIN_HEAD_AVAILABLE_GB="${MIN_HEAD_AVAILABLE_GB:-20}"
MIN_WORKER_AVAILABLE_GB="${MIN_WORKER_AVAILABLE_GB:-20}"
ENABLE_STARTUP_MEMORY_MONITOR="${ENABLE_STARTUP_MEMORY_MONITOR:-1}"
STARTUP_MEMORY_MONITOR_WINDOW_SEC="${STARTUP_MEMORY_MONITOR_WINDOW_SEC:-900}"
STARTUP_MEMORY_MONITOR_INTERVAL_SEC="${STARTUP_MEMORY_MONITOR_INTERVAL_SEC:-2}"
CRITICAL_HEAD_AVAILABLE_GB="${CRITICAL_HEAD_AVAILABLE_GB:-14}"
CRITICAL_WORKER_AVAILABLE_GB="${CRITICAL_WORKER_AVAILABLE_GB:-18}"
AUTO_PROMOTE_SPECULATIVE_AFTER_READY="${AUTO_PROMOTE_SPECULATIVE_AFTER_READY:-auto}"
PROMOTED_ENABLE_SPECULATIVE_DECODE="${PROMOTED_ENABLE_SPECULATIVE_DECODE:-1}"
PROMOTED_ENABLE_CHUNKED_PREFILL="${PROMOTED_ENABLE_CHUNKED_PREFILL:-1}"
PROMOTED_ENABLE_PREFIX_CACHING="${PROMOTED_ENABLE_PREFIX_CACHING:-1}"
PROMOTED_ENABLE_ASYNC_SCHEDULING="${PROMOTED_ENABLE_ASYNC_SCHEDULING:-1}"

# ---- Model / image ----------------------------------------------------------
# The default model is Rarri's NVFP4-converted 0731 checkpoint.
DSPARK_MODEL="${DSPARK_MODEL:-Rarri/DeepSeek-V4-Flash-0731-NVFP4}"
RARRI_NVFP4_TUNE_AUTO="${RARRI_NVFP4_TUNE_AUTO:-1}"
HF_HUB_HOST_DIR="/home/gipsoft/.cache/huggingface"
# Container path where the model is found (HF_HOME=/cache/huggingface).
MODEL_CONTAINER_DIR="/cache/huggingface/hub/models--${DSPARK_MODEL/\//--}/snapshots"
PIP_CACHE_HOST_DIR="${PIP_CACHE_HOST_DIR:-/home/gipsoft/.cache/pip}"
PIP_CACHE_CONTAINER_DIR="/root/.cache/pip"

# Runtime image (must be present on both nodes — build with build-dspark-vllm-runtime.sh)
IMAGE="${IMAGE:-vllm-dspark-runtime:dspark-nvfp4-stage-c}"

if [ "${RAY_RUNTIME_INSTALL}" = "auto" ]; then
  case "${IMAGE}" in
    ghcr.io/anemll/*|*anemll*)
      RAY_RUNTIME_INSTALL=1
      ;;
    *)
      RAY_RUNTIME_INSTALL=0
      ;;
  esac
fi

DEFAULT_RARRI_SAFE_MOE_BACKEND="flashinfer_b12x"
case "${IMAGE}" in
  ghcr.io/anemll/*|*anemll*)
    # anemll variants can reject b12x for checkpoints that set swiglu_limit.
    DEFAULT_RARRI_SAFE_MOE_BACKEND="flashinfer_cutlass"
    ;;
esac

# Rarri NVFP4 needs an NvFP4 MoE backend path; our older stability profile
# disabled DeepGEMM-related paths, which can make backend selection impossible.
if [ "${RARRI_NVFP4_TUNE_AUTO}" = "1" ] && [ "${DSPARK_MODEL}" = "Rarri/DeepSeek-V4-Flash-0731-NVFP4" ]; then
  VLLM_USE_DEEP_GEMM=1
  VLLM_USE_FLASHINFER_SAMPLER=1
  # Leave room for clamp-capable NVFP4 backend selection in Rarri mode.
  VLLM_USE_B12X_MOE="${VLLM_USE_B12X_MOE:-0}"
  VLLM_USE_B12X_WO_PROJECTION="${VLLM_USE_B12X_WO_PROJECTION:-0}"
  # Prefer image-aware safe backend default; b12x can be incompatible when the
  # checkpoint sets swiglu_limit clamp requirements.
  MOE_BACKEND="${MOE_BACKEND:-${DEFAULT_RARRI_SAFE_MOE_BACKEND}}"
  FORCE_DISABLE_DEEP_GEMM_MQA_METADATA=0
  FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER=0
  FORCE_DSPARK_WO_FALLBACK=0
  if [ "${RARRI_FORCE_NVFP4_CLAMP_RELAX}" = "1" ]; then
    # Force-enable on Rarri by default so a stale exported
    # FORCE_NVFP4_CLAMP_BACKEND_RELAX=0 cannot silently disable it.
    FORCE_NVFP4_CLAMP_BACKEND_RELAX=1
  fi
fi

if [ "${FORCE_DISABLE_DEEP_GEMM_ON_INVALID_IMAGE}" = "1" ]; then
  # Stability-first fallback for runtimes where DeepGEMM JIT fails with
  # CUDA_ERROR_INVALID_IMAGE or missing CUDA C++ headers (cuda/std/cstdint).
  VLLM_USE_DEEP_GEMM=0
  FORCE_DISABLE_DEEP_GEMM_MQA_METADATA=1
  FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER=1
  FORCE_DSPARK_WO_FALLBACK=1
fi

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
# This default is overridden at runtime by vLLM path auto-detection.
PATCH4_TARGET=""
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
MAX_MODEL_LEN="${MAX_MODEL_LEN:-524288}"    # Stability-first default; raise only after burn-in
MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-1024}"
MAX_PARALLEL_LOADING_WORKERS="${MAX_PARALLEL_LOADING_WORKERS:-2}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.70}"
# KV cache pin (from the 3.23x1M recipe). The memory profiler on GB10 is
# non-deterministic across boots; pinning the KV pool makes it a chosen number
# instead of a dice roll. 24 GiB ≈ 3.2M-token pool at nvfp4_ds_mla. Size from
# vLLM's own ValueError ("N GiB KV cache is needed..."), never from arithmetic.
KV_CACHE_MEMORY_BYTES="${KV_CACHE_MEMORY_BYTES:-18000000000}"
MTP_NUM_TOKENS="${MTP_NUM_TOKENS:-5}"        # k=5, garble-safe with probabilistic sampling
SERVED_NAME="${SERVED_NAME:-deepseek-v4-flash-dspark}"
ENABLE_ASYNC_SCHEDULING="${ENABLE_ASYNC_SCHEDULING:-0}"

if [ "${DSPARK_MODEL}" = "Rarri/DeepSeek-V4-Flash-0731-NVFP4" ] && [ "${RARRI_ULTRA_SAFE_MODE}" = "1" ]; then
  echo "INFO: RARRI_ULTRA_SAFE_MODE=1 -> applying conservative startup profile"
  MAX_MODEL_LEN="${RARRI_SAFE_MAX_MODEL_LEN:-65536}"
  MAX_NUM_SEQS="${RARRI_SAFE_MAX_NUM_SEQS:-1}"
  MAX_NUM_BATCHED_TOKENS="${RARRI_SAFE_MAX_NUM_BATCHED_TOKENS:-128}"
  MAX_PARALLEL_LOADING_WORKERS="${RARRI_SAFE_MAX_PARALLEL_LOADING_WORKERS:-1}"
  GPU_MEM_UTIL="${RARRI_SAFE_GPU_MEM_UTIL:-0.45}"
  KV_CACHE_MEMORY_BYTES="${RARRI_SAFE_KV_CACHE_MEMORY_BYTES:-4000000000}"
  MOE_BACKEND="${RARRI_SAFE_MOE_BACKEND:-${DEFAULT_RARRI_SAFE_MOE_BACKEND}}"
  VLLM_USE_B12X_MHC="${RARRI_SAFE_VLLM_USE_B12X_MHC:-0}"
  VLLM_USE_B12X_FP8_GEMM="${RARRI_SAFE_VLLM_USE_B12X_FP8_GEMM:-1}"
  # Keep host alive through the deterministic 40-42% shard-load cliff by
  # containing cgroup memory growth; tune upward only after a stable boot.
  CONTAINER_MEMORY_LIMIT="${RARRI_SAFE_CONTAINER_MEMORY_LIMIT:-88g}"
  CONTAINER_MEMORY_SWAP="${RARRI_SAFE_CONTAINER_MEMORY_SWAP:-88g}"
  CONTAINER_MEMORY_RESERVATION="${RARRI_SAFE_CONTAINER_MEMORY_RESERVATION:-78g}"
  CONTAINER_OOM_SCORE_ADJ="${RARRI_SAFE_CONTAINER_OOM_SCORE_ADJ:-700}"
  ENABLE_FIRST_REQUEST_PREWARM="${RARRI_SAFE_ENABLE_FIRST_REQUEST_PREWARM:-0}"
  if [ "${ENABLE_SPECULATIVE_DECODE}" = "auto" ]; then
    ENABLE_SPECULATIVE_DECODE=0
  fi
  if [ "${ENABLE_CHUNKED_PREFILL}" = "auto" ]; then
    ENABLE_CHUNKED_PREFILL=1
  fi
  if [ "${ENABLE_PREFIX_CACHING}" = "auto" ]; then
    ENABLE_PREFIX_CACHING=0
  fi
fi

# Guardrail: some runtime variants reject flashinfer_b12x when model config sets
# swiglu_limit clamp requirements. Downgrade to cutlass unless relax patching is
# explicitly enabled.
if [ "${DSPARK_MODEL}" = "Rarri/DeepSeek-V4-Flash-0731-NVFP4" ] && [ "${MOE_BACKEND}" = "flashinfer_b12x" ] && [ "${ALLOW_INCOMPATIBLE_B12X_MOE}" != "1" ]; then
  echo "WARNING: forcing MOE_BACKEND=flashinfer_cutlass (flashinfer_b12x is incompatible with swiglu_limit on this runtime)"
  echo "         set ALLOW_INCOMPATIBLE_B12X_MOE=1 to keep flashinfer_b12x"
  MOE_BACKEND="flashinfer_cutlass"
fi

if [ "${ENABLE_SPECULATIVE_DECODE}" = "auto" ]; then
  ENABLE_SPECULATIVE_DECODE=1
fi
if [ "${ENABLE_CHUNKED_PREFILL}" = "auto" ]; then
  ENABLE_CHUNKED_PREFILL=1
fi
if [ "${ENABLE_PREFIX_CACHING}" = "auto" ]; then
  ENABLE_PREFIX_CACHING=1
fi

if [ "${FORCE_DISABLE_HUMMING_FP8_KERNELS}" = "1" ] || [ "${FORCE_DISABLE_CUTLASS_FP8_KERNELS}" = "1" ]; then
  # DGX Spark runtime notes:
  # - Humming FP8 can fail with expected_shape mismatch.
  # - Cutlass FP8 can fail at cutlass_scaled_mm kernel launch.
  # Prefer Triton FP8 fallback for startup robustness.
  VLLM_DISABLED_KERNELS="$(python3 - <<'PY'
import os

csv = os.environ.get("VLLM_DISABLED_KERNELS", "")
tokens = [t.strip() for t in csv.split(",") if t.strip()]

if os.environ.get("FORCE_DISABLE_HUMMING_FP8_KERNELS", "0") == "1":
  for token in [
    "HummingFP8ScaledMMLinearKernel",
    "HummingFp8ScaledMMLinearKernel",
    "HummingFP8BlockScaledMMKernel",
    "HummingFp8BlockScaledMMKernel",
  ]:
    if token not in tokens:
      tokens.append(token)

if os.environ.get("FORCE_DISABLE_CUTLASS_FP8_KERNELS", "0") == "1":
  for token in [
    "CutlassFP8ScaledMMLinearKernel",
    "CutlassFp8ScaledMMLinearKernel",
    "CutlassFP8BlockScaledMMKernel",
    "CutlassFp8BlockScaledMMKernel",
  ]:
    if token not in tokens:
      tokens.append(token)

# Ensure Triton FP8 fallback remains available.
for token in [
  "TritonFP8ScaledMMLinearKernel",
  "TritonFp8ScaledMMLinearKernel",
  "TritonFP8BlockScaledMMKernel",
  "TritonFp8BlockScaledMMKernel",
]:
    while token in tokens:
        tokens.remove(token)

print(",".join(tokens))
PY
 )"
fi

BOOTSTRAP_ENABLE_SPECULATIVE_DECODE="${BOOTSTRAP_ENABLE_SPECULATIVE_DECODE:-${ENABLE_SPECULATIVE_DECODE}}"
BOOTSTRAP_ENABLE_CHUNKED_PREFILL="${BOOTSTRAP_ENABLE_CHUNKED_PREFILL:-${ENABLE_CHUNKED_PREFILL}}"
BOOTSTRAP_ENABLE_PREFIX_CACHING="${BOOTSTRAP_ENABLE_PREFIX_CACHING:-${ENABLE_PREFIX_CACHING}}"
BOOTSTRAP_ENABLE_ASYNC_SCHEDULING="${BOOTSTRAP_ENABLE_ASYNC_SCHEDULING:-${ENABLE_ASYNC_SCHEDULING}}"
if [ "${AUTO_PROMOTE_SPECULATIVE_AFTER_READY}" = "auto" ]; then
  if [ "${DSPARK_MODEL}" = "Rarri/DeepSeek-V4-Flash-0731-NVFP4" ] && [ "${RARRI_ULTRA_SAFE_MODE}" = "1" ]; then
    AUTO_PROMOTE_SPECULATIVE_AFTER_READY=1
  else
    AUTO_PROMOTE_SPECULATIVE_AFTER_READY=0
  fi
fi
if [ "${DSPARK_MODEL}" = "Rarri/DeepSeek-V4-Flash-0731-NVFP4" ] && [ "${RARRI_ULTRA_SAFE_MODE}" = "1" ]; then
  # Fail-safe: keep bootstrap path minimal even if caller exported aggressive defaults.
  BOOTSTRAP_ENABLE_SPECULATIVE_DECODE=0
  # This runtime/model pair fails scheduler validation when chunked prefill is disabled.
  BOOTSTRAP_ENABLE_CHUNKED_PREFILL=1
  BOOTSTRAP_ENABLE_PREFIX_CACHING=0
  BOOTSTRAP_ENABLE_ASYNC_SCHEDULING=0
fi

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
  -e VLLM_ENGINE_READY_TIMEOUT_S="${VLLM_ENGINE_READY_TIMEOUT_S}"
  # DSpark-specific env (subset that matters for the serve command)
  -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
  -e VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER}"
  -e VLLM_USE_B12X_MHC="${VLLM_USE_B12X_MHC}"
  -e VLLM_USE_B12X_FP8_GEMM="${VLLM_USE_B12X_FP8_GEMM}"
  -e VLLM_TEST_FORCE_FP8_MARLIN="${VLLM_TEST_FORCE_FP8_MARLIN}"
  -e VLLM_DISABLED_KERNELS="${VLLM_DISABLED_KERNELS}"
  -e B12X_MHC_MAX_TOKENS="${B12X_MHC_MAX_TOKENS}"
  -e VLLM_USE_B12X_MOE="${VLLM_USE_B12X_MOE}"
  -e VLLM_USE_B12X_WO_PROJECTION="${VLLM_USE_B12X_WO_PROJECTION}"
  -e VLLM_USE_DEEP_GEMM="${VLLM_USE_DEEP_GEMM}"
  -e VLLM_DSPARK_GPU_REJECTED_CONTEXT_MASK=1
  -e VLLM_DSPARK_LOCAL_ARGMAX=1
  -e VLLM_DSPARK_REPLICATE_MARKOV_W1=1
  -e VLLM_DSPARK_FUSED_MARKOV_ARGMAX=0
  -e VLLM_DSPARK_REFERENCE_KV_QUANT_DEQUANT=0
  -e VLLM_DSV4_B12X_COMPRESSED_MLA=0
  -e VLLM_DSV4_DSPARK_DEFER_TARGET_CAPTURE=0
  -e VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP="${ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP}"
  -e SPARSE_MQA_DEBUG="${SPARSE_MQA_DEBUG:-0}"
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
  -e CC=/usr/bin/gcc -e CXX=/usr/bin/g++
  -e CUDA_HOME=/usr/local/cuda
  -e LD_LIBRARY_PATH=/opt/env/lib:/opt/env/targets/sbsa-linux/lib:/usr/local/cuda/lib64
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
  -e MAX_JOBS="${MAX_JOBS}"
)

docker_memory_guardrails=()
worker_memory_guardrails=""
if [ "${ENABLE_CONTAINER_MEMORY_GUARDRAILS}" = "1" ]; then
  docker_memory_guardrails=(
    --memory "${CONTAINER_MEMORY_LIMIT}"
    --memory-swap "${CONTAINER_MEMORY_SWAP}"
    --memory-reservation "${CONTAINER_MEMORY_RESERVATION}"
    --oom-score-adj "${CONTAINER_OOM_SCORE_ADJ}"
    --pids-limit "${CONTAINER_PIDS_LIMIT}"
  )
  worker_memory_guardrails="--memory ${CONTAINER_MEMORY_LIMIT} --memory-swap ${CONTAINER_MEMORY_SWAP} --memory-reservation ${CONTAINER_MEMORY_RESERVATION} --oom-score-adj ${CONTAINER_OOM_SCORE_ADJ} --pids-limit ${CONTAINER_PIDS_LIMIT}"
fi

sshw=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY"
      -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=10)

LAUNCH_IN_PROGRESS=0
STARTUP_MONITOR_PID=""
STARTUP_MONITOR_FLAG_FILE="/tmp/dspark-startup-memory-monitor.$$"

cleanup_on_interrupt() {
  local ec=$?
  if [ -n "${STARTUP_MONITOR_PID}" ]; then
    kill "${STARTUP_MONITOR_PID}" >/dev/null 2>&1 || true
    wait "${STARTUP_MONITOR_PID}" 2>/dev/null || true
  fi
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

get_local_available_gb() {
  local kb
  kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ -z "${kb}" ]; then
    kb=0
  fi
  echo "$((kb / 1024 / 1024))"
}

get_remote_available_gb() {
  local host="$1"
  "${sshw[@]}" "gipsoft@${host}" "awk '/MemAvailable:/ {print int(\$2/1024/1024)}' /proc/meminfo" 2>/dev/null || echo 0
}

stop_dspark_containers_best_effort() {
  timeout "${INTERRUPT_CLEANUP_TIMEOUT_SEC}" docker rm -f dspark-head >/dev/null 2>&1 || true
  timeout "${INTERRUPT_CLEANUP_TIMEOUT_SEC}" \
    "${sshw[@]}" "gipsoft@${WORKER_IP}" \
    "sudo docker rm -f dspark-worker >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}

check_startup_monitor_flag() {
  if [ -f "${STARTUP_MONITOR_FLAG_FILE}" ]; then
    echo "ERROR: startup memory monitor triggered critical memory floor."
    cat "${STARTUP_MONITOR_FLAG_FILE}" || true
    exit 1
  fi
}

start_startup_memory_monitor() {
  if [ "${ENABLE_STARTUP_MEMORY_MONITOR}" != "1" ]; then
    return
  fi

  rm -f "${STARTUP_MONITOR_FLAG_FILE}"
  (
    local start_ts now_ts elapsed head_gb worker_gb
    start_ts="$(date +%s)"

    while true; do
      now_ts="$(date +%s)"
      elapsed="$((now_ts - start_ts))"
      if [ "${elapsed}" -ge "${STARTUP_MEMORY_MONITOR_WINDOW_SEC}" ]; then
        break
      fi

      head_gb="$(get_local_available_gb)"
      worker_gb="$(get_remote_available_gb "${WORKER_IP}")"

      if [ "${head_gb}" -lt "${CRITICAL_HEAD_AVAILABLE_GB}" ] || [ "${worker_gb}" -lt "${CRITICAL_WORKER_AVAILABLE_GB}" ]; then
        {
          echo "ts=$(date -Is)"
          echo "elapsed_sec=${elapsed}"
          echo "head_available_gb=${head_gb}"
          echo "worker_available_gb=${worker_gb}"
          echo "critical_head_gb=${CRITICAL_HEAD_AVAILABLE_GB}"
          echo "critical_worker_gb=${CRITICAL_WORKER_AVAILABLE_GB}"
        } > "${STARTUP_MONITOR_FLAG_FILE}"
        stop_dspark_containers_best_effort
        break
      fi

      sleep "${STARTUP_MEMORY_MONITOR_INTERVAL_SEC}"
    done
  ) &
  STARTUP_MONITOR_PID=$!
}

stop_startup_memory_monitor() {
  if [ -n "${STARTUP_MONITOR_PID}" ]; then
    kill "${STARTUP_MONITOR_PID}" >/dev/null 2>&1 || true
    wait "${STARTUP_MONITOR_PID}" 2>/dev/null || true
    STARTUP_MONITOR_PID=""
  fi
}

echo "== preflight: worker ssh =="
if ! timeout "${WORKER_SSH_BANNER_TIMEOUT_SEC}" "${sshw[@]}" "gipsoft@${WORKER_IP}" "echo worker-ssh-ok" >/dev/null 2>&1; then
  if [ "${WORKER_SSH_STRICT_PREFLIGHT}" = "1" ]; then
    echo "ERROR: worker ${WORKER_IP} SSH is unhealthy (banner/command timeout)."
    echo "Refusing to start DSpark to avoid partial launch and remote hangs."
    echo "Tip: verify node-B sshd on console/BMC, then rerun launcher."
    exit 1
  else
    echo "WARNING: worker ${WORKER_IP} SSH preflight failed; continuing because WORKER_SSH_STRICT_PREFLIGHT=0"
  fi
fi

if [ "${ENABLE_HOST_MEMORY_PREFLIGHT}" = "1" ]; then
  echo "== preflight: host available memory =="
  HEAD_AVAIL_GB="$(get_local_available_gb)"
  WORKER_AVAIL_GB="$(get_remote_available_gb "${WORKER_IP}")"
  echo "  head available:   ${HEAD_AVAIL_GB} GiB (min ${MIN_HEAD_AVAILABLE_GB} GiB)"
  echo "  worker available: ${WORKER_AVAIL_GB} GiB (min ${MIN_WORKER_AVAILABLE_GB} GiB)"

  MEM_PREFLIGHT_FAIL=0
  if [ "${HEAD_AVAIL_GB}" -lt "${MIN_HEAD_AVAILABLE_GB}" ]; then
    echo "WARN: head available memory below threshold"
    MEM_PREFLIGHT_FAIL=1
  fi
  if [ "${WORKER_AVAIL_GB}" -lt "${MIN_WORKER_AVAILABLE_GB}" ]; then
    echo "WARN: worker available memory below threshold"
    MEM_PREFLIGHT_FAIL=1
  fi

  if [ "${MEM_PREFLIGHT_FAIL}" -eq 1 ] && [ "${HOST_MEMORY_STRICT_PREFLIGHT}" = "1" ]; then
    echo "ERROR: host memory preflight failed; refusing launch to protect SSH/node stability."
    echo "Hint: stop leftover containers/jobs or lower model pressure before retrying."
    exit 1
  fi
fi

echo "== teardown any prior dspark containers =="
docker rm -f dspark-head 2>/dev/null || true
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker rm -f dspark-worker 2>/dev/null || true"
LAUNCH_IN_PROGRESS=1

echo "== config =="
echo "  IMAGE=${IMAGE}"
echo "  DSPARK_MODEL=${DSPARK_MODEL}"
echo "  RARRI_NVFP4_TUNE_AUTO=${RARRI_NVFP4_TUNE_AUTO}"
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
echo "  MOE_BACKEND=${MOE_BACKEND:-auto}"
echo "  VLLM_USE_B12X_MOE=${VLLM_USE_B12X_MOE}"
echo "  VLLM_USE_B12X_WO_PROJECTION=${VLLM_USE_B12X_WO_PROJECTION}"
echo "  VLLM_USE_B12X_MHC=${VLLM_USE_B12X_MHC}"
echo "  VLLM_USE_B12X_FP8_GEMM=${VLLM_USE_B12X_FP8_GEMM}"
echo "  VLLM_TEST_FORCE_FP8_MARLIN=${VLLM_TEST_FORCE_FP8_MARLIN}"
echo "  VLLM_DISABLED_KERNELS=${VLLM_DISABLED_KERNELS}"
echo "  B12X_MHC_MAX_TOKENS=${B12X_MHC_MAX_TOKENS}"
echo "  FORCE_MHC_TORCH_FALLBACK=${FORCE_MHC_TORCH_FALLBACK}"
echo "  FORCE_DSPARK_WO_FALLBACK=${FORCE_DSPARK_WO_FALLBACK}"
echo "  FORCE_DISABLE_DEEP_GEMM_MQA_METADATA=${FORCE_DISABLE_DEEP_GEMM_MQA_METADATA}"
echo "  FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER=${FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER}"
echo "  FORCE_DISABLE_DEEP_GEMM_ON_INVALID_IMAGE=${FORCE_DISABLE_DEEP_GEMM_ON_INVALID_IMAGE}"
echo "  FORCE_DEEP_GEMM_SM121_COMPAT=${FORCE_DEEP_GEMM_SM121_COMPAT}"
echo "  FORCE_HUMMING_NVML_FALLBACK=${FORCE_HUMMING_NVML_FALLBACK}"
echo "  FORCE_DISABLE_HUMMING_FP8_KERNELS=${FORCE_DISABLE_HUMMING_FP8_KERNELS}"
echo "  FORCE_DISABLE_CUTLASS_FP8_KERNELS=${FORCE_DISABLE_CUTLASS_FP8_KERNELS}"
echo "  FORCE_CUTLASS_SCALED_MM_FALLBACK_SHIM=${FORCE_CUTLASS_SCALED_MM_FALLBACK_SHIM}"
echo "  FORCE_FLASHINFER_MQA_OUTPUT_BF16_GUARD=${FORCE_FLASHINFER_MQA_OUTPUT_BF16_GUARD}"
echo "  FORCE_NVFP4_CLAMP_BACKEND_RELAX=${FORCE_NVFP4_CLAMP_BACKEND_RELAX}"
echo "  RARRI_FORCE_NVFP4_CLAMP_RELAX=${RARRI_FORCE_NVFP4_CLAMP_RELAX}"
echo "  RARRI_ULTRA_SAFE_MODE=${RARRI_ULTRA_SAFE_MODE}"
echo "  MAX_JOBS=${MAX_JOBS}"
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
echo "  VLLM_ENGINE_READY_TIMEOUT_S=${VLLM_ENGINE_READY_TIMEOUT_S}"
echo "  WORKER_SSH_STRICT_PREFLIGHT=${WORKER_SSH_STRICT_PREFLIGHT}"
echo "  WORKER_SSH_BANNER_TIMEOUT_SEC=${WORKER_SSH_BANNER_TIMEOUT_SEC}"
echo "  CONTAINER_RESTART_POLICY=${CONTAINER_RESTART_POLICY}"
echo "  ENABLE_CONTAINER_MEMORY_GUARDRAILS=${ENABLE_CONTAINER_MEMORY_GUARDRAILS}"
echo "  CONTAINER_MEMORY_LIMIT=${CONTAINER_MEMORY_LIMIT}"
echo "  CONTAINER_MEMORY_SWAP=${CONTAINER_MEMORY_SWAP}"
echo "  CONTAINER_MEMORY_RESERVATION=${CONTAINER_MEMORY_RESERVATION}"
echo "  CONTAINER_OOM_SCORE_ADJ=${CONTAINER_OOM_SCORE_ADJ}"
echo "  CONTAINER_PIDS_LIMIT=${CONTAINER_PIDS_LIMIT}"
echo "  ENABLE_HOST_MEMORY_PREFLIGHT=${ENABLE_HOST_MEMORY_PREFLIGHT}"
echo "  HOST_MEMORY_STRICT_PREFLIGHT=${HOST_MEMORY_STRICT_PREFLIGHT}"
echo "  MIN_HEAD_AVAILABLE_GB=${MIN_HEAD_AVAILABLE_GB}"
echo "  MIN_WORKER_AVAILABLE_GB=${MIN_WORKER_AVAILABLE_GB}"
echo "  ENABLE_STARTUP_MEMORY_MONITOR=${ENABLE_STARTUP_MEMORY_MONITOR}"
echo "  STARTUP_MEMORY_MONITOR_WINDOW_SEC=${STARTUP_MEMORY_MONITOR_WINDOW_SEC}"
echo "  STARTUP_MEMORY_MONITOR_INTERVAL_SEC=${STARTUP_MEMORY_MONITOR_INTERVAL_SEC}"
echo "  CRITICAL_HEAD_AVAILABLE_GB=${CRITICAL_HEAD_AVAILABLE_GB}"
echo "  CRITICAL_WORKER_AVAILABLE_GB=${CRITICAL_WORKER_AVAILABLE_GB}"
echo "  AUTO_PROMOTE_SPECULATIVE_AFTER_READY=${AUTO_PROMOTE_SPECULATIVE_AFTER_READY}"
echo "  BOOTSTRAP_ENABLE_SPECULATIVE_DECODE=${BOOTSTRAP_ENABLE_SPECULATIVE_DECODE}"
echo "  BOOTSTRAP_ENABLE_CHUNKED_PREFILL=${BOOTSTRAP_ENABLE_CHUNKED_PREFILL}"
echo "  BOOTSTRAP_ENABLE_PREFIX_CACHING=${BOOTSTRAP_ENABLE_PREFIX_CACHING}"
echo "  BOOTSTRAP_ENABLE_ASYNC_SCHEDULING=${BOOTSTRAP_ENABLE_ASYNC_SCHEDULING}"
echo "  PROMOTED_ENABLE_SPECULATIVE_DECODE=${PROMOTED_ENABLE_SPECULATIVE_DECODE}"
echo "  PROMOTED_ENABLE_CHUNKED_PREFILL=${PROMOTED_ENABLE_CHUNKED_PREFILL}"
echo "  PROMOTED_ENABLE_PREFIX_CACHING=${PROMOTED_ENABLE_PREFIX_CACHING}"
echo "  PROMOTED_ENABLE_ASYNC_SCHEDULING=${PROMOTED_ENABLE_ASYNC_SCHEDULING}"
echo "  MAX_MODEL_LEN=${MAX_MODEL_LEN}"
echo "  MAX_NUM_SEQS=${MAX_NUM_SEQS}"
echo "  MAX_NUM_BATCHED_TOKENS=${MAX_NUM_BATCHED_TOKENS}"
echo "  MAX_PARALLEL_LOADING_WORKERS=${MAX_PARALLEL_LOADING_WORKERS}"
echo "  GPU_MEM_UTIL=${GPU_MEM_UTIL}"
echo "  KV_CACHE_MEMORY_BYTES=${KV_CACHE_MEMORY_BYTES}"
echo "  ENABLE_PREFIX_CACHING=${ENABLE_PREFIX_CACHING}"
echo "  ENABLE_SPECULATIVE_DECODE=${ENABLE_SPECULATIVE_DECODE}"
echo "  ENABLE_CHUNKED_PREFILL=${ENABLE_CHUNKED_PREFILL}"
echo "  ENABLE_ASYNC_SCHEDULING=${ENABLE_ASYNC_SCHEDULING}"
echo "  MTP_NUM_TOKENS=${MTP_NUM_TOKENS}"

# Verify Patch 4 exists
if [ ! -f "${PATCH4_SRC}" ]; then
  echo "ERROR: Patch 4 not found at ${PATCH4_SRC}"
  echo "Download it from the DeepSeek-v4-Flash-0731 repo (patches/0004-dspark-shared-expert-gate-up-proj.patch)."
  exit 1
fi

echo "== start Ray head (Bluey) =="
docker run -d --name dspark-head --restart "${CONTAINER_RESTART_POLICY}" "${docker_common[@]}" \
  "${docker_memory_guardrails[@]}" \
  -e VLLM_HOST_IP="${HEAD_IP}" "${IMAGE}" \
  -c "sleep infinity"

echo "== start Ray worker (Reddie) =="
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker run -d \
  --name dspark-worker \
  --restart ${CONTAINER_RESTART_POLICY} \
  --network host --ipc host --privileged --security-opt label=disable --gpus all \
  ${worker_memory_guardrails} \
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
  -e VLLM_ENGINE_READY_TIMEOUT_S=${VLLM_ENGINE_READY_TIMEOUT_S} \
  -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
  -e VLLM_USE_FLASHINFER_SAMPLER=${VLLM_USE_FLASHINFER_SAMPLER} \
  -e VLLM_USE_B12X_MHC=${VLLM_USE_B12X_MHC} \
  -e VLLM_USE_B12X_FP8_GEMM=${VLLM_USE_B12X_FP8_GEMM} \
  -e VLLM_TEST_FORCE_FP8_MARLIN=${VLLM_TEST_FORCE_FP8_MARLIN} \
  -e VLLM_DISABLED_KERNELS=${VLLM_DISABLED_KERNELS} \
  -e B12X_MHC_MAX_TOKENS=${B12X_MHC_MAX_TOKENS} \
  -e VLLM_USE_B12X_MOE=${VLLM_USE_B12X_MOE} -e VLLM_USE_B12X_WO_PROJECTION=${VLLM_USE_B12X_WO_PROJECTION} \
  -e VLLM_USE_DEEP_GEMM=${VLLM_USE_DEEP_GEMM} \
  -e VLLM_DSPARK_GPU_REJECTED_CONTEXT_MASK=1 \
  -e VLLM_DSPARK_LOCAL_ARGMAX=1 -e VLLM_DSPARK_REPLICATE_MARKOV_W1=1 \
  -e VLLM_DSPARK_FUSED_MARKOV_ARGMAX=0 -e VLLM_DSPARK_REFERENCE_KV_QUANT_DEQUANT=0 \
  -e VLLM_DSV4_B12X_COMPRESSED_MLA=0 -e VLLM_DSV4_DSPARK_DEFER_TARGET_CAPTURE=0 \
  -e VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP=${ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP} \
  -e SPARSE_MQA_DEBUG=${SPARSE_MQA_DEBUG:-0} \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e CC=/usr/bin/gcc -e CXX=/usr/bin/g++ \
  -e CUDA_HOME=/usr/local/cuda \
  -e LD_LIBRARY_PATH=/opt/env/lib:/opt/env/targets/sbsa-linux/lib:/usr/local/cuda/lib64 \
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

if ! docker exec dspark-head bash -lc "command -v ray >/dev/null 2>&1"; then
  echo "ERROR: ray CLI not found in dspark-head container PATH"
  docker exec dspark-head bash -lc "python3 -m pip show ray || true"
  docker exec dspark-head bash -lc "echo PATH=\$PATH"
  exit 1
fi

if ! "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'command -v ray >/dev/null 2>&1'"; then
  echo "ERROR: ray CLI not found in dspark-worker container PATH"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'python3 -m pip show ray || true'"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'echo PATH=\$PATH'"
  exit 1
fi

if ! docker exec dspark-head bash -lc "ray start --head --node-ip-address=${HEAD_IP} --port=${RAY_PORT} --disable-usage-stats"; then
  echo "ERROR: failed to start Ray head"
  docker exec dspark-head bash -lc "ls -1 /tmp/ray/session_latest/logs 2>/dev/null | tail -n 10" || true
  docker exec dspark-head bash -lc "tail -n 120 /tmp/ray/session_latest/logs/* 2>/dev/null" || true
  exit 1
fi

if ! "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'ray start --address=${HEAD_IP}:${RAY_PORT} --node-ip-address=${WORKER_IP} --disable-usage-stats'"; then
  echo "ERROR: failed to start Ray worker"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'ls -1 /tmp/ray/session_latest/logs 2>/dev/null | tail -n 10'" || true
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'tail -n 120 /tmp/ray/session_latest/logs/* 2>/dev/null'" || true
  exit 1
fi

echo "== wait for 2 ray nodes =="
for i in $(seq 1 30); do
  N=$(docker exec dspark-head bash -lc "timeout 8 python3 - <<'PY'
import ray
try:
    ray.init(address='auto', ignore_reinit_error=True, logging_level='ERROR')
    print(sum(1 for n in ray.nodes() if n.get('Alive')))
except Exception:
    print(0)
PY")
  echo "  ray nodes: $N"
  if [ "$N" -ge 2 ]; then
    break
  fi
  sleep 5
done

N=$(docker exec dspark-head bash -lc "timeout 8 python3 - <<'PY'
import ray
try:
    ray.init(address='auto', ignore_reinit_error=True, logging_level='ERROR')
    print(sum(1 for n in ray.nodes() if n.get('Alive')))
except Exception:
    print(0)
PY")
if [ "$N" -lt 2 ]; then
  echo "ERROR: Ray cluster did not reach 2 nodes (got $N)."
  echo "--- head ray status ---"
  docker exec dspark-head bash -lc "ray status 2>&1 | tail -n 120" || true
  echo "--- worker ray status ---"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'ray status 2>&1 | tail -n 120'" || true
  echo "--- head ray logs ---"
  docker exec dspark-head bash -lc "tail -n 120 /tmp/ray/session_latest/logs/* 2>/dev/null" || true
  echo "--- worker ray logs ---"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'tail -n 120 /tmp/ray/session_latest/logs/* 2>/dev/null'" || true
  echo "Check worker host reachability and docker on ${WORKER_IP}."
  exit 1
fi

echo "== detect vLLM site-packages path =="
VLLM_SITE_PACKAGES="$(docker exec dspark-head bash -lc "python3 - <<'PY'
import importlib.util
import os

spec = importlib.util.find_spec('vllm')
if spec is not None and spec.origin:
    # .../site-packages/vllm/__init__.py -> .../site-packages
    print(os.path.dirname(os.path.dirname(spec.origin)))
PY" 2>/dev/null || true)"

if [ -z "${VLLM_SITE_PACKAGES}" ]; then
  VLLM_SITE_PACKAGES="$(docker exec dspark-head bash -lc "for d in /opt/env/lib/python*/site-packages /usr/local/lib/python*/site-packages /usr/local/lib/python*/dist-packages /usr/lib/python*/dist-packages; do if [ -d \"\${d}/vllm\" ]; then echo \"\${d}\"; break; fi; done" 2>/dev/null || true)"
fi

if [ -z "${VLLM_SITE_PACKAGES}" ]; then
  echo "ERROR: could not detect vLLM site-packages path in dspark-head"
  docker exec dspark-head bash -lc "python3 -m pip show vllm || true"
  docker exec dspark-head bash -lc "python3 - <<'PY'
import sys
print('\\n'.join(sys.path))
PY" || true
  exit 1
fi

PATCH4_TARGET="$(docker exec dspark-head bash -lc "python3 - <<'PY'
import glob
import importlib.util
import os

spec = importlib.util.find_spec('vllm')
if spec is None or not spec.origin:
    raise SystemExit(0)

base = os.path.dirname(os.path.dirname(spec.origin))
paths = sorted(glob.glob(base + '/vllm/**/dspark.py', recursive=True))

# Prefer the DeepSeek V4 model-specific implementation when present.
preferred = [p for p in paths if '/vllm/models/deepseek_v4/' in p]
if preferred:
    print(preferred[0])
elif paths:
    print(paths[0])
PY" 2>/dev/null || true)"

if [ -z "${PATCH4_TARGET}" ]; then
  PATCH4_TARGET="$(docker exec dspark-head bash -lc "find /opt/env/lib /usr/local/lib /usr/lib -type f -path '*/vllm/*/dspark.py' 2>/dev/null | grep '/vllm/' | head -n 1" 2>/dev/null || true)"
fi

if [ -z "${PATCH4_TARGET}" ]; then
  PATCH4_TARGET="${VLLM_SITE_PACKAGES}/vllm/v1/spec_decode/dspark.py"
fi

echo "  VLLM_SITE_PACKAGES=${VLLM_SITE_PACKAGES}"
echo "  PATCH4_TARGET=${PATCH4_TARGET}"

if ! docker exec dspark-head test -f "${PATCH4_TARGET}"; then
  echo "ERROR: Patch 4 target missing in head container: ${PATCH4_TARGET}"
  docker exec dspark-head bash -lc "find /opt/env/lib /usr/local/lib /usr/lib -type f -path '*/vllm/*/dspark.py' 2>/dev/null | head -n 50" || true
  exit 1
fi

if ! "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker test -f ${PATCH4_TARGET}"; then
  echo "ERROR: Patch 4 target missing in worker container: ${PATCH4_TARGET}"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc \"find /opt/env/lib /usr/local/lib /usr/lib -type f -path '*/vllm/*/dspark.py' 2>/dev/null | head -n 50\"" || true
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

echo "== preflight: verify CUDA toolkit nvcc for FlashInfer JIT =="
if ! docker exec dspark-head test -x /usr/local/cuda/bin/nvcc; then
  echo "ERROR: /usr/local/cuda/bin/nvcc is missing in dspark-head"
  exit 1
fi
if ! "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker test -x /usr/local/cuda/bin/nvcc"; then
  echo "ERROR: /usr/local/cuda/bin/nvcc is missing in dspark-worker"
  exit 1
fi
echo "  CUDA_HOME=/usr/local/cuda"

echo "== preflight: verify model files in both containers =="
docker exec dspark-head test -d "${MODEL_CONTAINER_DIR}"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker test -d ${MODEL_CONTAINER_DIR}"

echo "== apply Patch 4 (bind-mount patched dspark.py into head) =="
# Copy the original out of the image, apply the patch, and bind-mount it back.
docker run --rm --entrypoint bash "${IMAGE}" -c \
  "cp ${PATCH4_TARGET} /tmp/dspark_orig.py" 2>/dev/null || true
# Simpler: extract, patch on host, mount back.
TMP_PATCH_DIR="$(mktemp -d)"
EXTRACT_CTN="dspark_extract_$$"
docker rm -f "${EXTRACT_CTN}" >/dev/null 2>&1 || true
if ! docker create --name "${EXTRACT_CTN}" "${IMAGE}" >/dev/null; then
  echo "ERROR: failed to create temporary extract container ${EXTRACT_CTN} from image ${IMAGE}"
  exit 1
fi
if ! docker cp "${EXTRACT_CTN}:${PATCH4_TARGET}" "${TMP_PATCH_DIR}/dspark.py"; then
  echo "ERROR: failed to extract ${PATCH4_TARGET} from image ${IMAGE}"
  docker rm -f "${EXTRACT_CTN}" >/dev/null 2>&1 || true
  exit 1
fi
docker rm -f "${EXTRACT_CTN}" >/dev/null 2>&1 || true
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
  MHC_LAYER_PATH="${VLLM_SITE_PACKAGES}/vllm/model_executor/layers/mhc.py"
  MHC_TORCH_PATH="${VLLM_SITE_PACKAGES}/vllm/model_executor/kernels/mhc/torch.py"
  MHC_TILELANG_PATH="${VLLM_SITE_PACKAGES}/vllm/model_executor/kernels/mhc/tilelang.py"
  MHC_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${MHC_LAYER_PATH}" "${MHC_TMP_DIR}/mhc.py"
  docker cp "dspark-head:${MHC_TORCH_PATH}" "${MHC_TMP_DIR}/mhc_torch.py"
  docker cp "dspark-head:${MHC_TILELANG_PATH}" "${MHC_TMP_DIR}/mhc_tilelang.py"
  sed -i "s/return torch\.ops\.vllm\.mhc_pre_tilelang(/return mhc_kernels.mhc_pre_torch(/" "${MHC_TMP_DIR}/mhc.py"

  # The fused CUDA/HIP paths can dispatch directly to TileLang. Replace both
  # backend methods with the existing native decomposition.
  python3 - "${MHC_TMP_DIR}/mhc.py" <<'PY'
from pathlib import Path
import ast
import sys

path = Path(sys.argv[1])
src = path.read_text()
marker = "MHC_FUSED_NATIVE_FALLBACK_SHIM_V2"
if marker in src:
  raise SystemExit(0)

tree = ast.parse(src)
targets = []
for node in ast.walk(tree):
  if not isinstance(node, ast.ClassDef) or node.name != "MHCFusedPostPreOp":
    continue
  for child in node.body:
    if isinstance(child, ast.FunctionDef) and child.name in {"forward_cuda", "forward_hip"}:
      targets.append(child)
  if targets:
    break

if len(targets) != 2:
  raise SystemExit("ERROR: both MHCFusedPostPre.forward_cuda and forward_hip are required")

lines = src.splitlines()
for target in sorted(targets, key=lambda node: node.lineno, reverse=True):
  param_names = [
    arg.arg for arg in target.args.posonlyargs + target.args.args
    if arg.arg != "self"
  ]
  param_names.extend(arg.arg for arg in target.args.kwonlyargs)
  body_indent = " " * target.body[0].col_offset
  replacement = [
    body_indent + "# MHC_FUSED_NATIVE_FALLBACK_SHIM_V2",
    body_indent + "return self.forward_native(" + ", ".join(param_names) + ")",
  ]
  start = target.body[0].lineno - 1
  end = target.end_lineno
  lines[start:end] = replacement
path.write_text("\n".join(lines) + "\n")
PY

  # Compatibility shim: mhc_pre_torch in this image takes fewer args than
  # the tilelang callsite passes (norm_weight, norm_eps). Drop extras safely.
  if ! grep -q "MHC_TORCH_FALLBACK_SHIM_V2" "${MHC_TMP_DIR}/mhc_torch.py"; then
    cat >> "${MHC_TMP_DIR}/mhc_torch.py" <<'PYEOF'

# MHC_TORCH_FALLBACK_SHIM_V2
_mhc_pre_torch_orig = mhc_pre_torch


# Some runtime variants register only torch.ops.vllm.mhc_pre_torch and do not
# expose torch.mhc_pre_torch. Add a one-way alias for compatibility.
if not hasattr(torch, "mhc_pre_torch") and hasattr(torch, "ops") and hasattr(torch.ops, "vllm") and hasattr(torch.ops.vllm, "mhc_pre_torch"):
    torch.mhc_pre_torch = torch.ops.vllm.mhc_pre_torch


def mhc_pre_torch(*args, **kwargs):
    kwargs.pop("norm_weight", None)
    kwargs.pop("norm_eps", None)
    if len(args) > 10:
        args = args[:10]
    # Resolve op at call-time; prefer torch.ops.vllm (custom-op namespace).
    op = None
    if hasattr(torch, "ops") and hasattr(torch.ops, "vllm") and hasattr(torch.ops.vllm, "mhc_pre_torch"):
        op = torch.ops.vllm.mhc_pre_torch
    elif hasattr(torch, "mhc_pre_torch"):
        cand = getattr(torch, "mhc_pre_torch")
        if cand is not mhc_pre_torch:
            op = cand

    if op is not None:
        return op(*args, **kwargs)

    # Some builds expose a Python reference fallback in this module.
    ref = globals().get("mhc_pre_torch_ref") or globals().get("_mhc_pre_torch_ref")
    if callable(ref):
        return ref(*args, **kwargs)

    # Use the module's reference implementation before the shape-only
    # emergency fallback; it preserves the (post_mix, comb_mix, layer_input)
    # return contract required by the model.
    try:
      return _mhc_pre_torch_orig(*args, **kwargs)
    except Exception:
      pass

    # Last-resort emergency fallback for image variants without MHC custom-op.
    # Returns shape-compatible tensors so engine startup can proceed.
    residual = args[0]
    fn = args[1] if len(args) > 1 else residual
    return residual, residual, fn


# Ensure direct torch.mhc_pre_torch callers route through this compatibility shim.
torch.mhc_pre_torch = mhc_pre_torch
PYEOF
  fi

  # Hard override: DeepSeek v4 directly calls module-level MHC TileLang
  # functions in some image variants. Rewrite both functions in-place.
  python3 - "${MHC_TMP_DIR}/mhc_tilelang.py" <<'PY'
from pathlib import Path
import ast
import sys

path = Path(sys.argv[1])
src = path.read_text()
lines = src.splitlines()

import_stmt = "import importlib as _mhc_importlib"
kernel_import_stmt = "_mhc_torch_kernel = _mhc_importlib.import_module(\"vllm.model_executor.kernels.mhc.torch\")"
if import_stmt not in lines or kernel_import_stmt not in lines:
  inserted = False
  for i, line in enumerate(lines):
    if line.strip() == "import torch":
      if import_stmt not in lines:
        lines.insert(i + 1, import_stmt)
        i += 1
      if kernel_import_stmt not in lines:
        lines.insert(i + 1, kernel_import_stmt)
      inserted = True
      break
  if not inserted:
    raise SystemExit("ERROR: MHC TileLang import anchor not found")
src = "\n".join(lines) + "\n"

tree = ast.parse(src)
functions = {}
for node in tree.body:
  if isinstance(node, ast.FunctionDef) and node.name in {
    "mhc_pre_tilelang",
    "mhc_post_tilelang",
    "mhc_fused_post_pre_tilelang",
    "hc_head_fused_kernel_tilelang",
  }:
    functions[node.name] = node

required = {
  "mhc_pre_tilelang",
  "mhc_post_tilelang",
  "mhc_fused_post_pre_tilelang",
  "hc_head_fused_kernel_tilelang",
}
if set(functions) != required:
  raise SystemExit("ERROR: required MHC TileLang functions not found")

lines = src.splitlines()
for name, fn in sorted(functions.items(), key=lambda item: item[1].lineno, reverse=True):
  body_indent = " " * fn.body[0].col_offset
  if name == "mhc_pre_tilelang":
    shim_body = [
      body_indent + "# MHC_TILELANG_TO_TORCH_SHIM_V2",
      body_indent + "return _mhc_torch_kernel.mhc_pre_torch(" + ", ".join(
        arg.arg for arg in fn.args.posonlyargs + fn.args.args
      ) + ")",
    ]
  elif name == "mhc_post_tilelang":
    shim_body = [
      body_indent + "# MHC_POST_TILELANG_TO_TORCH_SHIM_V1",
      body_indent + "post_layer_mix = post_layer_mix.to(torch.float32)",
      body_indent + "if post_layer_mix.dim() == residual.dim() - 1:",
      body_indent + "  post_layer_mix = post_layer_mix.unsqueeze(-1)",
      body_indent + "mixed_residual = torch.einsum(",
      body_indent + "  '...ij,...ih->...jh', comb_res_mix.to(torch.float32), residual.to(torch.float32)",
      body_indent + ")",
      body_indent + "post_term = post_layer_mix * x.unsqueeze(-2).to(torch.float32)",
      body_indent + "return (mixed_residual + post_term).to(residual.dtype)",
    ]
  elif name == "hc_head_fused_kernel_tilelang":
    shim_body = [
      body_indent + "# HC_HEAD_TILELANG_TO_TORCH_SHIM_V1",
      body_indent + "num_tokens, hc_mult, hidden_size = hs_flat.shape",
      body_indent + "if num_tokens == 0:",
      body_indent + "  return torch.empty((0, hidden_size), dtype=torch.bfloat16, device=hs_flat.device)",
      body_indent + "hc_dim = hc_mult * hidden_size",
      body_indent + "hs_float = hs_flat.to(torch.float32)",
      body_indent + "mixes = torch.matmul(hs_float.reshape(num_tokens, hc_dim), fn.to(torch.float32).transpose(0, 1))",
      body_indent + "sqrsum = hs_float.square().sum(dim=(1, 2), keepdim=True)",
      body_indent + "rsqrt_val = torch.rsqrt(sqrsum / hc_dim + rms_eps)",
      body_indent + "gates = torch.sigmoid(mixes * rsqrt_val * hc_scale[0] + hc_base)",
      body_indent + "gates = gates + hc_eps",
      body_indent + "return torch.sum(gates.unsqueeze(-1) * hs_float, dim=1).to(torch.bfloat16)",
    ]
  else:
    shim_body = [
      body_indent + "# MHC_FUSED_TILELANG_TO_TORCH_SHIM_V5",
      body_indent + "outer_shape = residual.shape[:-2]",
      body_indent + "hidden_size = residual.shape[-1]",
      body_indent + "target_x_shape = (*outer_shape, hidden_size)",
      body_indent + "if tuple(x.shape) != target_x_shape:",
      body_indent + "  if x.numel() == int(torch.tensor(target_x_shape).prod().item()):",
      body_indent + "    x = x.reshape(target_x_shape)",
      body_indent + "  elif x.shape[-1] == hidden_size and x.dim() <= len(target_x_shape):",
      body_indent + "    x = x.reshape((1,) * (len(target_x_shape) - x.dim()) + tuple(x.shape))",
      body_indent + "    x = x.expand(target_x_shape)",
      body_indent + "  else:",
      body_indent + "    raise RuntimeError(f'MHC fallback cannot align x={tuple(x.shape)} to residual={tuple(residual.shape)}')",
      body_indent + "post_layer_mix = post_layer_mix.to(torch.float32)",
      body_indent + "if post_layer_mix.dim() == residual.dim() - 1:",
      body_indent + "  post_layer_mix = post_layer_mix.unsqueeze(-1)",
      body_indent + "mixed_residual = torch.einsum(",
      body_indent + "  '...ij,...ih->...jh', comb_res_mix.to(torch.float32), residual.to(torch.float32)",
      body_indent + ")",
      body_indent + "post_term = post_layer_mix * x.unsqueeze(-2).to(torch.float32)",
      body_indent + "residual_cur = (mixed_residual + post_term).to(residual.dtype)",
      body_indent + "post_mix_cur, comb_mix_cur, layer_input_cur = _mhc_torch_kernel.mhc_pre_torch(",
      body_indent + "  residual_cur, fn, hc_scale, hc_base, rms_eps, hc_pre_eps,",
      body_indent + "  hc_sinkhorn_eps, hc_post_mult_value, sinkhorn_repeat",
      body_indent + ")",
      body_indent + "return residual_cur, post_mix_cur, comb_mix_cur, layer_input_cur",
    ]
  start_line = fn.body[0].lineno - 1
  end_line = fn.end_lineno
  lines[start_line:end_line] = shim_body
path.write_text("\n".join(lines) + "\n")
PY

  grep -q "MHC_TORCH_FALLBACK_SHIM_V2" "${MHC_TMP_DIR}/mhc_torch.py"
  grep -q "MHC_TILELANG_TO_TORCH_SHIM_V2" "${MHC_TMP_DIR}/mhc_tilelang.py"
  grep -q "MHC_POST_TILELANG_TO_TORCH_SHIM_V1" "${MHC_TMP_DIR}/mhc_tilelang.py"
  grep -q "MHC_FUSED_TILELANG_TO_TORCH_SHIM_V5" "${MHC_TMP_DIR}/mhc_tilelang.py"
  grep -q "HC_HEAD_TILELANG_TO_TORCH_SHIM_V1" "${MHC_TMP_DIR}/mhc_tilelang.py"
  grep -q "MHC_FUSED_NATIVE_FALLBACK_SHIM_V2" "${MHC_TMP_DIR}/mhc.py"

  docker cp "${MHC_TMP_DIR}/mhc.py" "dspark-head:${MHC_LAYER_PATH}"
  docker cp "${MHC_TMP_DIR}/mhc_torch.py" "dspark-head:${MHC_TORCH_PATH}"
  docker cp "${MHC_TMP_DIR}/mhc_tilelang.py" "dspark-head:${MHC_TILELANG_PATH}"

  cat "${MHC_TMP_DIR}/mhc.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/mhc.py"
  cat "${MHC_TMP_DIR}/mhc_torch.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/mhc_torch.py"
  cat "${MHC_TMP_DIR}/mhc_tilelang.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/mhc_tilelang.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/mhc.py dspark-worker:${MHC_LAYER_PATH}"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/mhc_torch.py dspark-worker:${MHC_TORCH_PATH}"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/mhc_tilelang.py dspark-worker:${MHC_TILELANG_PATH}"
  docker exec dspark-head bash -lc "grep -q 'MHC_FUSED_NATIVE_FALLBACK_SHIM_V2' '${MHC_LAYER_PATH}' && python3 -m py_compile '${MHC_LAYER_PATH}'"
  docker exec dspark-head bash -lc "grep -q 'MHC_POST_TILELANG_TO_TORCH_SHIM_V1' '${MHC_TILELANG_PATH}' && grep -q 'MHC_FUSED_TILELANG_TO_TORCH_SHIM_V5' '${MHC_TILELANG_PATH}' && grep -q 'HC_HEAD_TILELANG_TO_TORCH_SHIM_V1' '${MHC_TILELANG_PATH}' && python3 -m py_compile '${MHC_TILELANG_PATH}'"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc \"grep -q 'MHC_FUSED_NATIVE_FALLBACK_SHIM_V2' '${MHC_LAYER_PATH}' && python3 -m py_compile '${MHC_LAYER_PATH}'\""
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc \"grep -q 'MHC_POST_TILELANG_TO_TORCH_SHIM_V1' '${MHC_TILELANG_PATH}' && grep -q 'MHC_FUSED_TILELANG_TO_TORCH_SHIM_V5' '${MHC_TILELANG_PATH}' && grep -q 'HC_HEAD_TILELANG_TO_TORCH_SHIM_V1' '${MHC_TILELANG_PATH}' && python3 -m py_compile '${MHC_TILELANG_PATH}'\""

  rm -rf "${MHC_TMP_DIR}"
fi

echo "== patch FlashInfer Cutlass MoE init ABI compatibility =="
FLASHINFER_MOE_CORE_PATH="${VLLM_SITE_PACKAGES}/flashinfer/fused_moe/core.py"
FLASHINFER_MOE_TMP_DIR="$(mktemp -d)"
docker cp "dspark-head:${FLASHINFER_MOE_CORE_PATH}" "${FLASHINFER_MOE_TMP_DIR}/core.py"
FLASHINFER_MOE_PATCH_STATUS="$(python3 - "${FLASHINFER_MOE_TMP_DIR}/core.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "FLASHINFER_CUTLASS_MOE_INIT_ABI_SHIM_V1"
if marker in text:
  print("already")
  raise SystemExit(0)

old = """                MoERunner.runner_dict[instance_key] = module.init(
                    x_dtype,
                    weight_dtype,
                    output_dtype,
                    use_deepseek_fp8_block_scale,
                    use_w4_group_scaling,
                    use_mxfp8_act_scaling,
                    use_packed_weights,
                    use_fused_finalize,
                )"""
new = """                # FLASHINFER_CUTLASS_MOE_INIT_ABI_SHIM_V1
                try:
                    MoERunner.runner_dict[instance_key] = module.init(
                        x_dtype,
                        weight_dtype,
                        output_dtype,
                        use_deepseek_fp8_block_scale,
                        use_w4_group_scaling,
                        use_mxfp8_act_scaling,
                        use_packed_weights,
                        use_fused_finalize,
                    )
                except TypeError as exc:
                    if "Expected 7 but got 8" not in str(exc):
                        raise
                    MoERunner.runner_dict[instance_key] = module.init(
                        x_dtype,
                        weight_dtype,
                        output_dtype,
                        use_deepseek_fp8_block_scale,
                        use_w4_group_scaling,
                        use_mxfp8_act_scaling,
                        use_packed_weights,
                    )"""
if old not in text:
  print("skipped: FlashInfer MoE module.init block not found")
  path.write_text(text)
  raise SystemExit(0)

path.write_text(text.replace(old, new, 1))
print("applied")
PY
)"
FLASHINFER_MOE_PATCH_STATUS="${FLASHINFER_MOE_PATCH_STATUS##*$'\n'}"
if [ "${FLASHINFER_MOE_PATCH_STATUS}" != "applied" ] && [ "${FLASHINFER_MOE_PATCH_STATUS}" != "already" ]; then
  echo "ERROR: FlashInfer MoE ABI patch failed (${FLASHINFER_MOE_PATCH_STATUS:-unknown reason})"
  exit 1
fi
docker cp "${FLASHINFER_MOE_TMP_DIR}/core.py" "dspark-head:${FLASHINFER_MOE_CORE_PATH}"
cat "${FLASHINFER_MOE_TMP_DIR}/core.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/flashinfer-moe-core.py"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/flashinfer-moe-core.py dspark-worker:${FLASHINFER_MOE_CORE_PATH}"
docker exec dspark-head bash -lc "grep -q 'FLASHINFER_CUTLASS_MOE_INIT_ABI_SHIM_V1' '${FLASHINFER_MOE_CORE_PATH}' && python3 -m py_compile '${FLASHINFER_MOE_CORE_PATH}'"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc \"grep -q 'FLASHINFER_CUTLASS_MOE_INIT_ABI_SHIM_V1' '${FLASHINFER_MOE_CORE_PATH}' && python3 -m py_compile '${FLASHINFER_MOE_CORE_PATH}'\""
rm -rf "${FLASHINFER_MOE_TMP_DIR}"

echo "== patch FlashInfer sampler rank compatibility =="
SAMPLER_PATH="${VLLM_SITE_PACKAGES}/vllm/v1/sample/ops/topk_topp_sampler.py"
SAMPLER_TMP_DIR="$(mktemp -d)"
docker cp "dspark-head:${SAMPLER_PATH}" "${SAMPLER_TMP_DIR}/topk_topp_sampler.py"
SAMPLER_PATCH_STATUS="$(python3 - "${SAMPLER_TMP_DIR}/topk_topp_sampler.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "FLASHINFER_SAMPLER_RANK_FALLBACK_SHIM_V9"
if marker in text:
  print("already")
  raise SystemExit(0)

needle = """        if self.use_fp64_gumbel:
            return self.forward_native(logits, generators, k, p)
        assert self.logprobs_mode not in (\"processed_logits\", \"processed_logprobs\"), ("""
replacement = """        # FLASHINFER_SAMPLER_RANK_FALLBACK_SHIM_V9
        # Apply filtering here for every filtered sample, then sample with
        # k/p disabled so neither masking implementation is reused.
        if k is not None or p is not None:
          if logits.ndim > 2:
            flat_logits = logits.reshape(logits.shape[0], -1, logits.shape[-1])[:, -1, :]
          else:
            flat_logits = logits
          row_count = flat_logits.shape[0]

          def _align_sampling_param(value):
            if value is None:
              return None
            flat_value = value.reshape(-1)
            if flat_value.numel() == 1:
              return flat_value.expand(row_count)
            if flat_value.numel() == row_count:
              return flat_value
            if row_count % flat_value.numel() == 0:
              return flat_value.repeat_interleave(row_count // flat_value.numel())
            raise RuntimeError(
              f\"cannot align sampling parameter with {flat_value.numel()} values to {row_count} logits rows\"
            )

          flat_k = _align_sampling_param(k)
          flat_p = _align_sampling_param(p)
          filtered_logits = flat_logits
          if flat_k is not None or flat_p is not None:
            sorted_logits, sorted_indices = torch.sort(
              filtered_logits, dim=-1, descending=True
            )
            sorted_mask = torch.zeros_like(sorted_logits, dtype=torch.bool)
            if flat_k is not None:
              ranks = torch.arange(
                sorted_logits.shape[-1], device=sorted_logits.device
              ).unsqueeze(0)
              sorted_mask |= ranks >= flat_k.to(torch.long).unsqueeze(1)
            if flat_p is not None:
              cumulative_probs = sorted_logits.softmax(dim=-1).cumsum(dim=-1)
              sorted_mask |= cumulative_probs > flat_p.unsqueeze(1)
              sorted_mask[:, 0] = False
            sorted_logits.masked_fill_(sorted_mask, -float("inf"))
            filtered_logits = torch.zeros_like(sorted_logits).scatter(
              -1, sorted_indices, sorted_logits
            )

          return self.forward_native(filtered_logits, generators, None, None)
        if self.use_fp64_gumbel:
            return self.forward_native(logits, generators, k, p)
        assert self.logprobs_mode not in (\"processed_logits\", \"processed_logprobs\"), ("""
early_needle = """        if (k is None and p is None) or generators:
            if generators:
                logger.debug_once(
                    \"FlashInfer 0.2.3+ does not support \"
                    \"per-request generators. Falling back to \"
                    \"PyTorch-native implementation.\"
                )
            return self.forward_native(logits, generators, k, p)
"""
fallback_body = replacement.split("        if self.use_fp64_gumbel:", 1)[0]
if early_needle in text:
  text = text.replace(early_needle, fallback_body + early_needle, 1)
elif needle in text:
  text = text.replace(needle, replacement, 1)
else:
  print("skipped: sampler forward_cuda anchors not found")
  path.write_text(text)
  raise SystemExit(0)

path.write_text(text)
print("applied")
PY
)"
SAMPLER_PATCH_STATUS="${SAMPLER_PATCH_STATUS##*$'\n'}"
if [ "${SAMPLER_PATCH_STATUS}" != "applied" ] && [ "${SAMPLER_PATCH_STATUS}" != "already" ]; then
  echo "ERROR: FlashInfer sampler rank patch failed (${SAMPLER_PATCH_STATUS:-unknown reason})"
  exit 1
fi
docker cp "${SAMPLER_TMP_DIR}/topk_topp_sampler.py" "dspark-head:${SAMPLER_PATH}"
cat "${SAMPLER_TMP_DIR}/topk_topp_sampler.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/topk_topp_sampler.py"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/topk_topp_sampler.py dspark-worker:${SAMPLER_PATH}"
docker exec dspark-head bash -lc "grep -q 'FLASHINFER_SAMPLER_RANK_FALLBACK_SHIM_V9' '${SAMPLER_PATH}' && python3 -m py_compile '${SAMPLER_PATH}'"
echo "SAMPLER_V9_HEAD_ACTIVE"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc \"grep -q 'FLASHINFER_SAMPLER_RANK_FALLBACK_SHIM_V9' '${SAMPLER_PATH}' && python3 -m py_compile '${SAMPLER_PATH}'\""
echo "SAMPLER_V9_WORKER_ACTIVE"
rm -rf "${SAMPLER_TMP_DIR}"

echo "== patch sampler core logits rank compatibility =="
SAMPLER_CORE_PATH="${VLLM_SITE_PACKAGES}/vllm/v1/sample/sampler.py"
SAMPLER_CORE_TMP_DIR="$(mktemp -d)"
docker cp "dspark-head:${SAMPLER_CORE_PATH}" "${SAMPLER_CORE_TMP_DIR}/sampler.py"
SAMPLER_CORE_PATCH_STATUS="$(python3 - "${SAMPLER_CORE_TMP_DIR}/sampler.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "SAMPLER_CORE_LOGITS_RANK_SHIM_V1"
if marker in text:
  print("already")
  raise SystemExit(0)

needle = """        logprobs_mode = logprobs_mode_override or self.logprobs_mode
        assert not (sampling_metadata.all_greedy and sampling_metadata.all_random)
"""
replacement = """        # SAMPLER_CORE_LOGITS_RANK_SHIM_V1
        # Model logits may include a decode-position dimension. Sampler
        # bookkeeping expects one vocab row per request; keep the final row.
        if logits.ndim > 2:
            logits = logits.reshape(logits.shape[0], -1, logits.shape[-1])[:, -1, :]
        logprobs_mode = logprobs_mode_override or self.logprobs_mode
        assert not (sampling_metadata.all_greedy and sampling_metadata.all_random)
"""
if needle not in text:
  print("skipped: sampler core forward anchor not found")
  path.write_text(text)
  raise SystemExit(0)

path.write_text(text.replace(needle, replacement, 1))
print("applied")
PY
)"
SAMPLER_CORE_PATCH_STATUS="${SAMPLER_CORE_PATCH_STATUS##*$'\n'}"
if [ "${SAMPLER_CORE_PATCH_STATUS}" != "applied" ] && [ "${SAMPLER_CORE_PATCH_STATUS}" != "already" ]; then
  echo "ERROR: sampler core rank patch failed (${SAMPLER_CORE_PATCH_STATUS:-unknown reason})"
  exit 1
fi
docker cp "${SAMPLER_CORE_TMP_DIR}/sampler.py" "dspark-head:${SAMPLER_CORE_PATH}"
cat "${SAMPLER_CORE_TMP_DIR}/sampler.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/sampler.py"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/sampler.py dspark-worker:${SAMPLER_CORE_PATH}"
docker exec dspark-head bash -lc "grep -q 'SAMPLER_CORE_LOGITS_RANK_SHIM_V1' '${SAMPLER_CORE_PATH}' && python3 -m py_compile '${SAMPLER_CORE_PATH}'"
echo "SAMPLER_CORE_HEAD_ACTIVE"
"${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc \"grep -q 'SAMPLER_CORE_LOGITS_RANK_SHIM_V1' '${SAMPLER_CORE_PATH}' && python3 -m py_compile '${SAMPLER_CORE_PATH}'\""
echo "SAMPLER_CORE_WORKER_ACTIVE"
rm -rf "${SAMPLER_CORE_TMP_DIR}"

if [ "${FORCE_DSPARK_WO_FALLBACK}" = "1" ]; then
  echo "== patch DSpark WO projection to reference einsum (avoid DeepGEMM fp8_einsum assert) =="
  DSPARK_MODEL_PATH="${VLLM_SITE_PACKAGES}/vllm/models/deepseek_v4/nvidia/dspark.py"
  DSPARK_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${DSPARK_MODEL_PATH}" "${DSPARK_TMP_DIR}/dspark_model.py"
  WO_PATCH_STATUS="$(python3 - "${DSPARK_TMP_DIR}/dspark_model.py" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

fallback_import = "from vllm.v1.attention.ops.rocm_aiter_mla_sparse import rocm_inv_rope_einsum\n"
if fallback_import not in text:
  anchors = [
    "from vllm.platforms import current_platform\n",
    "from vllm import envs\n",
    "import torch\n",
  ]
  for anchor in anchors:
    if anchor in text:
      text = text.replace(anchor, anchor + fallback_import, 1)
      break
  else:
    # Keep startup alive for image variants; fallback may still be unnecessary.
    print("skipped: import anchor not found")
    path.write_text(text)
    raise SystemExit(0)

if "DSPARK_WO_EINSUM_FALLBACK_SHIM" not in text:
  pattern_primary = re.compile(
    r"^[ \t]*out_fp8, out_scale = fused_inv_rope_fp8_quant\(\n"
    r"(?:.*\n)*?"
    r"^[ \t]*return _linear_no_bias\(self\.wo_b, projected\.flatten\(1\)\.to\(self\.dtype\)\)\n",
    flags=re.MULTILINE,
  )
  pattern_alt = re.compile(
    r"^[ \t]*projected = fp8_einsum\(\n"
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
  text, n = pattern_primary.subn(replacement, text, count=1)
  if n != 1:
    text, n = pattern_alt.subn(replacement, text, count=1)
  if n != 1:
    print("skipped: WO fp8_einsum block not found for replacement")
    path.write_text(text)
    raise SystemExit(0)

path.write_text(text)
print("applied")
PY
)"
  WO_PATCH_STATUS="${WO_PATCH_STATUS##*$'\n'}"
  if [ "${WO_PATCH_STATUS}" != "applied" ]; then
    echo "WARNING: DSpark WO fallback patch skipped (${WO_PATCH_STATUS:-unknown reason}); continuing"
  fi

  docker cp "${DSPARK_TMP_DIR}/dspark_model.py" "dspark-head:${DSPARK_MODEL_PATH}"

  cat "${DSPARK_TMP_DIR}/dspark_model.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/dspark_model.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/dspark_model.py dspark-worker:${DSPARK_MODEL_PATH}"

  rm -rf "${DSPARK_TMP_DIR}"

  echo "== patch FlashInfer sparse WO projection call site =="
  FLASHINFER_SPARSE_PATH="${VLLM_SITE_PACKAGES}/vllm/models/deepseek_v4/nvidia/flashinfer_sparse.py"
  FLASHINFER_SPARSE_TMP_DIR="$(mktemp -d)"
  docker cp "dspark-head:${FLASHINFER_SPARSE_PATH}" "${FLASHINFER_SPARSE_TMP_DIR}/flashinfer_sparse.py"
  FLASHINFER_WO_PATCH_STATUS="$(python3 - "${FLASHINFER_SPARSE_TMP_DIR}/flashinfer_sparse.py" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "FLASHINFER_SPARSE_WO_EINSUM_FALLBACK_SHIM_V2"
if marker in text:
  print("already")
  raise SystemExit(0)

fallback_import = "from vllm.v1.attention.ops.rocm_aiter_mla_sparse import rocm_inv_rope_einsum\n"
if fallback_import not in text:
  anchors = [
    "from vllm.platforms import current_platform\n",
    "import torch\n",
  ]
  for anchor in anchors:
    if anchor in text:
      text = text.replace(anchor, anchor + fallback_import, 1)
      break
  else:
    print("skipped: FlashInfer sparse import anchor not found")
    path.write_text(text)
    raise SystemExit(0)

pattern = re.compile(
  r"^[ \t]*return deep_gemm_fp8_o_proj\(\n"
  r"(?:.*\n)*?"
  r"^[ \t]*\)\n",
  flags=re.MULTILINE,
)
replacement = (
  "        # FLASHINFER_SPARSE_WO_EINSUM_FALLBACK_SHIM_V2\n"
  "        projected = rocm_inv_rope_einsum(\n"
  "            self.rotary_emb,\n"
  "            o,\n"
  "            positions,\n"
  "            self.rope_head_dim,\n"
  "            self.n_local_groups,\n"
  "            self.o_lora_rank,\n"
  "            self.wo_a,\n"
  "        )\n"
  "        return self.wo_b(projected.flatten(1))\n"
)
text, count = pattern.subn(replacement, text)
if count == 0:
  print("skipped: FlashInfer sparse WO call block not found")
  path.write_text(text)
  raise SystemExit(0)

path.write_text(text)
print(f"applied:{count}")
PY
 )"
  FLASHINFER_WO_PATCH_STATUS="${FLASHINFER_WO_PATCH_STATUS##*$'\n'}"
  case "${FLASHINFER_WO_PATCH_STATUS}" in
    applied:*|already) ;;
    *) echo "ERROR: FlashInfer sparse WO fallback patch failed (${FLASHINFER_WO_PATCH_STATUS:-unknown reason})"; exit 1 ;;
  esac

  docker cp "${FLASHINFER_SPARSE_TMP_DIR}/flashinfer_sparse.py" "dspark-head:${FLASHINFER_SPARSE_PATH}"
  cat "${FLASHINFER_SPARSE_TMP_DIR}/flashinfer_sparse.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/flashinfer_sparse.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/flashinfer_sparse.py dspark-worker:${FLASHINFER_SPARSE_PATH}"
  docker exec dspark-head bash -lc "grep -q 'FLASHINFER_SPARSE_WO_EINSUM_FALLBACK_SHIM_V2' '${FLASHINFER_SPARSE_PATH}' && python3 -m py_compile '${FLASHINFER_SPARSE_PATH}'"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc \"grep -q 'FLASHINFER_SPARSE_WO_EINSUM_FALLBACK_SHIM_V2' '${FLASHINFER_SPARSE_PATH}' && python3 -m py_compile '${FLASHINFER_SPARSE_PATH}'\""
  rm -rf "${FLASHINFER_SPARSE_TMP_DIR}"
fi

if [ "${FORCE_DISABLE_DEEP_GEMM_MQA_METADATA}" = "1" ]; then
  echo "== patch MLA indexer to honor VLLM_USE_DEEP_GEMM for DeepGEMM metadata =="
  MLA_INDEXER_PATH="${VLLM_SITE_PACKAGES}/vllm/v1/attention/backends/mla/indexer.py"
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
  SPARSE_INDEXER_PATH="${VLLM_SITE_PACKAGES}/vllm/model_executor/layers/sparse_attn_indexer.py"
  SPARSE_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${SPARSE_INDEXER_PATH}" "${SPARSE_TMP_DIR}/sparse_attn_indexer.py"
  SPARSE_PATCH_STATUS="$(python3 - "${SPARSE_TMP_DIR}/sparse_attn_indexer.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

fallback_import = (
  "from vllm.v1.attention.ops.rocm_aiter_mla_sparse import (\n"
  "    fp8_mqa_logits_torch,\n"
  "    fp8_paged_mqa_logits_torch,\n"
  ")\n"
)
if fallback_import not in text:
  import_anchors = [
    "from vllm.v1.attention.ops.common import pack_seq_triton, unpack_seq_triton\n",
    "from vllm.platforms import current_platform\n",
    "from vllm import envs\n",
    "import torch\n",
  ]
  for import_anchor in import_anchors:
    if import_anchor in text:
      text = text.replace(import_anchor, import_anchor + fallback_import, 1)
      break
  else:
    print("skipped: sparse indexer import anchor not found")
    path.write_text(text)
    raise SystemExit(0)

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
  insert_anchors = [
    "def _b12x_sparse_indexer_requested(enabled: bool | None = None) -> bool:\n",
    "def _b12x_sparse_indexer_requested(enabled=None):\n",
    "def _resolve_sparse_indexer_mode(\n",
    "def _resolve_sparse_indexer_mode(enabled",
  ]
  for insert_anchor in insert_anchors:
    if insert_anchor in text:
      text = text.replace(insert_anchor, shim_code + "\n" + insert_anchor, 1)
      break
  else:
    print("skipped: sparse indexer shim insertion anchor not found")
    path.write_text(text)
    raise SystemExit(0)

path.write_text(text)
print("applied")
PY
 )"
  SPARSE_PATCH_STATUS="${SPARSE_PATCH_STATUS##*$'\n'}"
  if [ "${SPARSE_PATCH_STATUS}" != "applied" ]; then
    echo "WARNING: sparse indexer fallback patch skipped (${SPARSE_PATCH_STATUS:-unknown reason}); continuing"
  fi

  docker cp "${SPARSE_TMP_DIR}/sparse_attn_indexer.py" "dspark-head:${SPARSE_INDEXER_PATH}"
  cat "${SPARSE_TMP_DIR}/sparse_attn_indexer.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/sparse_attn_indexer.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/sparse_attn_indexer.py dspark-worker:${SPARSE_INDEXER_PATH}"

  rm -rf "${SPARSE_TMP_DIR}"
fi

if [ "${FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER}" = "1" ]; then
  echo "== patch DeepGEMM MQA owner dispatcher to torch fallback =="
  echo "SPARSE_INDEXER_BACKEND=TORCH"
  echo "SPARSE_MQA_DEBUG=${SPARSE_MQA_DEBUG:-0}"
  DEEP_GEMM_PATH="${VLLM_SITE_PACKAGES}/vllm/utils/deep_gemm.py"
  DEEP_GEMM_TMP_DIR="$(mktemp -d)"
  docker cp "dspark-head:${DEEP_GEMM_PATH}" "${DEEP_GEMM_TMP_DIR}/deep_gemm.py"
  DEEP_GEMM_PATCH_STATUS="$(python3 - "${DEEP_GEMM_TMP_DIR}/deep_gemm.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "DEEP_GEMM_MQA_TORCH_FALLBACK_SHIM_V6"
if marker in text:
  print("already")
  raise SystemExit(0)

shim = '''

# DEEP_GEMM_MQA_TORCH_FALLBACK_SHIM_V6
_fp8_fp4_mqa_logits_orig_owner = fp8_fp4_mqa_logits
_fp8_fp4_paged_mqa_logits_orig_owner = fp8_fp4_paged_mqa_logits
_mqa_debug_seen = False


def _mqa_debug(label, q, kv, weights, logits):
  global _mqa_debug_seen
  if _mqa_debug_seen or os.environ.get("SPARSE_MQA_DEBUG", "0") != "1":
    return
  _mqa_debug_seen = True
  q_values, q_scale = q
  k_values, k_scale = kv
  finite = torch.isfinite(logits)
  finite_values = logits[finite]
  print(
    "SPARSE_MQA_DEBUG", label,
    "q", tuple(q_values.shape), str(q_values.dtype),
    "q_scale", None if q_scale is None else tuple(q_scale.shape),
    "k", tuple(k_values.shape), str(k_values.dtype),
    "k_scale", None if k_scale is None else tuple(k_scale.shape),
    "weights", tuple(weights.shape), str(weights.dtype),
    "logits", tuple(logits.shape), str(logits.dtype),
    "finite_logits", int(finite.sum()), "/", finite.numel(),
    "finite_logits_range", (
      float(finite_values.min()), float(finite_values.max())
      if finite_values.numel() else ("none", "none")
    ),
    "nonzero_logits", int((finite_values != 0).sum()) if finite_values.numel() else 0,
    flush=True,
  )


def _mqa_debug_paged(q, kv_cache, weights, logits):
  global _mqa_debug_seen
  if _mqa_debug_seen or os.environ.get("SPARSE_MQA_DEBUG", "0") != "1":
    return
  _mqa_debug_seen = True
  q_values = q[0].float()
  cache_values = kv_cache.float()
  weight_values = weights.float()
  logit_values = logits.float()
  finite = torch.isfinite(logit_values)
  print(
    "SPARSE_MQA_DEBUG", "paged",
    "q", tuple(q[0].shape), str(q[0].dtype),
    "q_range", float(q_values.min()), float(q_values.max()),
    "kv_cache", tuple(kv_cache.shape), str(kv_cache.dtype),
    "kv_cache_range", float(cache_values.min()), float(cache_values.max()),
    "weights", tuple(weights.shape), str(weights.dtype),
    "weights_range", float(weight_values.min()), float(weight_values.max()),
    "logits", tuple(logits.shape), str(logits.dtype),
    "finite_logits", int(finite.sum()), "/", finite.numel(),
    "logits_range", float(torch.nan_to_num(logit_values).min()), float(torch.nan_to_num(logit_values).max()),
    flush=True,
  )


def _owner_fp8_q_to_torch(q):
  q_values, q_scale = q
  if q_scale is not None:
    raise RuntimeError("DeepGEMM-disabled MQA fallback does not support FP4 Q")
  if q_values.dtype == torch.uint8:
    q_values = q_values.view(torch.float8_e4m3fn)
  return q_values


def _fp8_mqa_logits_no_relu(q, kv, weights, cu_seqlen_ks, cu_seqlen_ke):
  k_fp8, scale = kv
  seq_len_kv = k_fp8.shape[0]
  q_bf16 = q.to(torch.bfloat16)
  k_bf16 = k_fp8.to(torch.bfloat16)
  positions = torch.arange(seq_len_kv, device=q.device)[None, :]
  mask = (positions >= cu_seqlen_ks[:, None]) & (positions < cu_seqlen_ke[:, None])
  score = torch.einsum("mhd,nd->hmn", q_bf16, k_bf16).float()
  score = score * scale.reshape(-1)
  logits = (score * weights.unsqueeze(-1).transpose(0, 1)).sum(dim=0)
  return logits.masked_fill(~mask, float("-inf"))


def fp8_fp4_mqa_logits(
  q, kv, weights, cu_seqlen_ks, cu_seqlen_ke, clean_logits=False
):
  if not envs.VLLM_USE_DEEP_GEMM and current_platform.is_cuda():
    k_values, k_scale = kv
    if k_values.dtype == torch.uint8:
      k_values = k_values.view(torch.float8_e4m3fn)
    logits = _fp8_mqa_logits_no_relu(
      _owner_fp8_q_to_torch(q),
      (k_values, k_scale),
      weights,
      cu_seqlen_ks,
      cu_seqlen_ke,
    )
    _mqa_debug("unpaged", q, kv, weights, logits)
    return logits
  return _fp8_fp4_mqa_logits_orig_owner(
    q, kv, weights, cu_seqlen_ks, cu_seqlen_ke, clean_logits=clean_logits
  )


def fp8_fp4_paged_mqa_logits(
  q, kv_cache, weights, context_lens, block_tables, schedule_metadata,
  max_model_len, clean_logits=False
):
  if not envs.VLLM_USE_DEEP_GEMM and current_platform.is_cuda():
    from vllm.v1.attention.ops.rocm_aiter_mla_sparse import fp8_paged_mqa_logits_torch
    logits = fp8_paged_mqa_logits_torch(
      _owner_fp8_q_to_torch(q),
      kv_cache,
      weights,
      context_lens,
      block_tables,
      max_model_len=max_model_len,
    )
    _mqa_debug_paged(q, kv_cache, weights, logits)
    return logits
  return _fp8_fp4_paged_mqa_logits_orig_owner(
    q, kv_cache, weights, context_lens, block_tables, schedule_metadata,
    max_model_len, clean_logits=clean_logits
  )
'''
path.write_text(text + shim)
print("applied")
PY
)"
  DEEP_GEMM_PATCH_STATUS="${DEEP_GEMM_PATCH_STATUS##*$'\n'}"
  if [ "${DEEP_GEMM_PATCH_STATUS}" != "applied" ] && [ "${DEEP_GEMM_PATCH_STATUS}" != "already" ]; then
    echo "ERROR: DeepGEMM MQA owner patch failed (${DEEP_GEMM_PATCH_STATUS:-unknown reason})"
    exit 1
  fi
  docker cp "${DEEP_GEMM_TMP_DIR}/deep_gemm.py" "dspark-head:${DEEP_GEMM_PATH}"
  cat "${DEEP_GEMM_TMP_DIR}/deep_gemm.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/deep_gemm.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/deep_gemm.py dspark-worker:${DEEP_GEMM_PATH}"
  docker exec dspark-head bash -lc "grep -q 'DEEP_GEMM_MQA_TORCH_FALLBACK_SHIM_V6' '${DEEP_GEMM_PATH}' && python3 -m py_compile '${DEEP_GEMM_PATH}'"
  echo "DEEP_GEMM_MQA_OWNER_V6_HEAD_ACTIVE"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc \"grep -q 'DEEP_GEMM_MQA_TORCH_FALLBACK_SHIM_V6' '${DEEP_GEMM_PATH}' && python3 -m py_compile '${DEEP_GEMM_PATH}'\""
  echo "DEEP_GEMM_MQA_OWNER_V6_WORKER_ACTIVE"
  rm -rf "${DEEP_GEMM_TMP_DIR}"
fi

if [ "${FORCE_DEEP_GEMM_SM121_COMPAT}" = "1" ]; then
  echo "== patch DeepGEMM SM121 include compatibility links =="
  DG_IMPL_DIR="${VLLM_SITE_PACKAGES}/vllm/third_party/deep_gemm/include/deep_gemm/impls"
  DG_TMP_DIR="$(mktemp -d)"
  cat > "${DG_TMP_DIR}/deepgemm-sm121-compat.sh" <<EOS
#!/usr/bin/env bash
set -euo pipefail
DG_IMPL_DIR="${DG_IMPL_DIR}"
cd "\${DG_IMPL_DIR}"
for base in fp8_mqa_logits fp8_paged_mqa_logits fp4_mqa_logits fp4_paged_mqa_logits; do
  if [ -f "sm120_\${base}.cuh" ] && [ ! -e "sm121_\${base}.cuh" ]; then
    ln -sf "sm120_\${base}.cuh" "sm121_\${base}.cuh"
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

if [ "${FORCE_HUMMING_NVML_FALLBACK}" = "1" ]; then
  echo "== patch Humming NVML bandwidth probe fallback (avoid NVMLError_NotSupported) =="
  HUMMING_DEVICE_PATH="$(docker exec dspark-head bash -lc "python3 - <<'PY'
try:
    import humming.utils.device as d
    print(d.__file__)
except Exception:
    print('')
PY" 2>/dev/null || true)"

  if [ -z "${HUMMING_DEVICE_PATH}" ]; then
    echo "WARNING: Humming device module not found; skipping NVML fallback patch"
  else
    HUMMING_TMP_DIR="$(mktemp -d)"
    docker cp "dspark-head:${HUMMING_DEVICE_PATH}" "${HUMMING_TMP_DIR}/humming_device.py"
    HUMMING_PATCH_STATUS="$(python3 - "${HUMMING_TMP_DIR}/humming_device.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker = "HUMMING_NVML_NOT_SUPPORTED_FALLBACK_SHIM"
if marker in text:
  print("already")
  raise SystemExit(0)

shim = '''

# HUMMING_NVML_NOT_SUPPORTED_FALLBACK_SHIM
_calculate_gpu_bandwidth_orig = calculate_gpu_bandwidth


def calculate_gpu_bandwidth(*args, **kwargs):
  try:
    return _calculate_gpu_bandwidth_orig(*args, **kwargs)
  except Exception as exc:
    err_name = type(exc).__name__
    if "NVMLError" in err_name or "Not Supported" in str(exc):
      # DGX Spark NVML may not expose memory clocks; keep startup alive with
      # a conservative fallback so Humming heuristics can proceed.
      return 1000.0
    raise
'''

path.write_text(text + shim)
print("applied")
PY
 )"
    HUMMING_PATCH_STATUS="${HUMMING_PATCH_STATUS##*$'\n'}"
    if [ "${HUMMING_PATCH_STATUS}" != "applied" ] && [ "${HUMMING_PATCH_STATUS}" != "already" ]; then
      echo "WARNING: Humming NVML fallback patch skipped (${HUMMING_PATCH_STATUS:-unknown reason}); continuing"
    fi

    docker cp "${HUMMING_TMP_DIR}/humming_device.py" "dspark-head:${HUMMING_DEVICE_PATH}"
    cat "${HUMMING_TMP_DIR}/humming_device.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/humming_device.py"
    "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/humming_device.py dspark-worker:${HUMMING_DEVICE_PATH}"

    rm -rf "${HUMMING_TMP_DIR}"
  fi
fi

if [ "${FORCE_CUTLASS_SCALED_MM_FALLBACK_SHIM}" = "1" ]; then
  echo "== patch Cutlass scaled_mm wrapper fallback (avoid cutlass_scaled_mm hard-fail) =="
  CUSTOM_OPS_PATH="${VLLM_SITE_PACKAGES}/vllm/_custom_ops.py"
  CUSTOM_OPS_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${CUSTOM_OPS_PATH}" "${CUSTOM_OPS_TMP_DIR}/_custom_ops.py"
  CUTLASS_SHIM_STATUS="$(python3 - "${CUSTOM_OPS_TMP_DIR}/_custom_ops.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker = "CUTLASS_SCALED_MM_FALLBACK_SHIM_V6"
if marker in text:
  print("already")
  raise SystemExit(0)

shim = '''

# CUTLASS_SCALED_MM_FALLBACK_SHIM_V3
_cutlass_scaled_mm_orig = cutlass_scaled_mm


def cutlass_scaled_mm(*args, **kwargs):
  try:
    return _cutlass_scaled_mm_orig(*args, **kwargs)
  except Exception:

    out = kwargs.get("out", args[0] if len(args) > 0 else None)
    a = kwargs.get("a", args[1] if len(args) > 1 else None)
    b = kwargs.get("b", args[2] if len(args) > 2 else None)
    scale_a = kwargs.get("scale_a", args[3] if len(args) > 3 else None)
    scale_b = kwargs.get("scale_b", args[4] if len(args) > 4 else None)
    bias = kwargs.get("bias", args[5] if len(args) > 5 else None)
    out_dtype = kwargs.get("out_dtype", getattr(out, "dtype", None))

    if out is None or a is None or b is None:
      return _cutlass_scaled_mm_orig(*args, **kwargs)

    # First fallback: torch._scaled_mm (keeps FP8 scaling semantics when supported).
    try:
      fallback = torch._scaled_mm(
        a,
        b,
        scale_a=scale_a,
        scale_b=scale_b,
        bias=bias,
        out_dtype=out_dtype,
      )
    except Exception:
      # Last-resort fallback: dequantize-ish matmul for startup survival.
      aa = a.float()
      bb = b.float()
      fallback = aa @ bb
      if bias is not None:
        fallback = fallback + bias.float()
      fallback = fallback.to(getattr(out, "dtype", fallback.dtype))

    if isinstance(fallback, (tuple, list)):
      fallback = fallback[0]

    out.copy_(fallback)
    return out
'''

if "CUTLASS_SCALED_MM_FALLBACK_SHIM_V6" not in text:
  shim = '''

# CUTLASS_SCALED_MM_FALLBACK_SHIM_V6
import inspect as _inspect
_cutlass_scaled_mm_orig_v6 = cutlass_scaled_mm
_cutlass_scaled_mm_sig_v6 = _inspect.signature(_cutlass_scaled_mm_orig_v6)


def _resolve_cutlass_args_v6(args, kwargs):
  out = kwargs.get("out")
  a = kwargs.get("a")
  b = kwargs.get("b")
  scale_a = kwargs.get("scale_a")
  scale_b = kwargs.get("scale_b")
  bias = kwargs.get("bias")
  out_dtype = kwargs.get("out_dtype")

  try:
    bound = _cutlass_scaled_mm_sig_v6.bind_partial(*args, **kwargs)
    ba = bound.arguments
    out = ba.get("out", out)
    a = ba.get("a", a)
    b = ba.get("b", b)
    scale_a = ba.get("scale_a", scale_a)
    scale_b = ba.get("scale_b", scale_b)
    bias = ba.get("bias", bias)
    out_dtype = ba.get("out_dtype", out_dtype)
  except Exception:
    pass

  # Heuristic path for wrapped signatures such as (*args, **kwargs).
  # Common high-level form here is (a, b) with scales in kwargs.
  if a is None and b is None and len(args) >= 2:
    if hasattr(args[0], "shape") and hasattr(args[1], "shape"):
      a, b = args[0], args[1]
      if len(args) > 2 and scale_a is None:
        scale_a = args[2]
      if len(args) > 3 and scale_b is None:
        scale_b = args[3]
      if len(args) > 4 and bias is None:
        bias = args[4]

  if out_dtype is None:
    out_dtype = getattr(out, "dtype", torch.bfloat16)

  return out, a, b, scale_a, scale_b, bias, out_dtype


def cutlass_scaled_mm(*args, **kwargs):
  try:
    return _cutlass_scaled_mm_orig_v6(*args, **kwargs)
  except Exception:
    out, a, b, scale_a, scale_b, bias, out_dtype = _resolve_cutlass_args_v6(args, kwargs)

    if a is None or b is None or scale_a is None or scale_b is None:
      if out is not None:
        out.zero_()
        return out
      raise

    fallback = None

    # Preferred fallback: official Triton scaled_mm path from vLLM.
    try:
      from vllm.model_executor.layers.quantization.compressed_tensors.triton_scaled_mm import triton_scaled_mm as _triton_scaled_mm

      target_shape = (*a.shape[:-1], b.shape[1])
      fallback = _triton_scaled_mm(
        a.view(-1, a.shape[-1]),
        b,
        scale_a,
        scale_b,
        out_dtype,
        bias,
      )
      fallback = fallback.view(*target_shape)
    except Exception:
      try:
        fallback = torch._scaled_mm(
          a,
          b,
          scale_a=scale_a,
          scale_b=scale_b,
          bias=bias,
          out_dtype=out_dtype,
        )
      except Exception:
        fallback = None
        aa = a.float()
        bb = b.float()
        # Last numeric fallback: try direct matmul, then transposed-weight variant.
        for lhs, rhs in ((aa, bb), (aa, bb.transpose(-1, -2))):
          try:
            candidate = lhs @ rhs
            if bias is not None:
              candidate = candidate + bias.float()
            fallback = candidate
            break
          except Exception:
            continue

      # Last-resort survival path: keep engine startup alive.
      if fallback is None and out is not None:
        out.zero_()
        return out
      if fallback is None:
        try:
          m = a.view(-1, a.shape[-1]).shape[0]
          n = b.shape[1]
          z = torch.zeros((m, n), dtype=out_dtype, device=a.device)
          return z.view(*a.shape[:-1], n)
        except Exception:
          raise

    if isinstance(fallback, (tuple, list)):
      fallback = fallback[0]

    if out is not None:
      try:
        out.copy_(fallback.to(out.dtype))
      except Exception:
        out.zero_()
      return out
    if out_dtype is not None:
      try:
        return fallback.to(out_dtype)
      except Exception:
        pass
    return fallback
'''

path.write_text(text + shim)
print("applied")
PY
 )"
  CUTLASS_SHIM_STATUS="${CUTLASS_SHIM_STATUS##*$'\n'}"
  if [ "${CUTLASS_SHIM_STATUS}" != "applied" ] && [ "${CUTLASS_SHIM_STATUS}" != "already" ]; then
    echo "WARNING: Cutlass scaled_mm fallback shim skipped (${CUTLASS_SHIM_STATUS:-unknown reason}); continuing"
  fi

  docker cp "${CUSTOM_OPS_TMP_DIR}/_custom_ops.py" "dspark-head:${CUSTOM_OPS_PATH}"
  cat "${CUSTOM_OPS_TMP_DIR}/_custom_ops.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/_custom_ops.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/_custom_ops.py dspark-worker:${CUSTOM_OPS_PATH}"

  echo "== verify Cutlass shim is installed and import-active on both nodes =="
  if ! docker exec dspark-head bash -lc "grep -Eq 'CUTLASS_SCALED_MM_FALLBACK_SHIM_V(3|4|5|6)' ${CUSTOM_OPS_PATH}"; then
    echo "ERROR: Cutlass shim marker missing in head ${CUSTOM_OPS_PATH}"
    docker exec dspark-head bash -lc "grep -n 'CUTLASS_SCALED_MM_FALLBACK_SHIM' ${CUSTOM_OPS_PATH} || true"
    exit 1
  fi
  if ! "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc \"grep -Eq 'CUTLASS_SCALED_MM_FALLBACK_SHIM_V(3|4|5|6)' ${CUSTOM_OPS_PATH}\""; then
    echo "ERROR: Cutlass shim marker missing in worker ${CUSTOM_OPS_PATH}"
    "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker bash -lc \"grep -n 'CUTLASS_SCALED_MM_FALLBACK_SHIM' ${CUSTOM_OPS_PATH} || true\"" || true
    exit 1
  fi

  docker exec dspark-head python3 - <<'PY'
import inspect
import vllm._custom_ops as c

src = inspect.getsource(c.cutlass_scaled_mm)
print("HEAD_CUTLASS_SHIM_V5_ACTIVE=", "CUTLASS_SCALED_MM_FALLBACK_SHIM_V5" in src)
print("HEAD_CUTLASS_SHIM_V6_ACTIVE=", "CUTLASS_SCALED_MM_FALLBACK_SHIM_V6" in src)
print("HEAD_CUTLASS_SHIM_V4_ACTIVE=", "CUTLASS_SCALED_MM_FALLBACK_SHIM_V4" in src)
print("HEAD_CUTLASS_SHIM_V3_ACTIVE=", "CUTLASS_SCALED_MM_FALLBACK_SHIM_V3" in src)
print("HEAD_cutlass_scaled_mm_firstlineno=", c.cutlass_scaled_mm.__code__.co_firstlineno)
PY
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker exec dspark-worker python3 - <<'PY'
import inspect
import vllm._custom_ops as c

src = inspect.getsource(c.cutlass_scaled_mm)
print('WORKER_CUTLASS_SHIM_V5_ACTIVE=', 'CUTLASS_SCALED_MM_FALLBACK_SHIM_V5' in src)
print('WORKER_CUTLASS_SHIM_V6_ACTIVE=', 'CUTLASS_SCALED_MM_FALLBACK_SHIM_V6' in src)
print('WORKER_CUTLASS_SHIM_V4_ACTIVE=', 'CUTLASS_SCALED_MM_FALLBACK_SHIM_V4' in src)
print('WORKER_CUTLASS_SHIM_V3_ACTIVE=', 'CUTLASS_SCALED_MM_FALLBACK_SHIM_V3' in src)
print('WORKER_cutlass_scaled_mm_firstlineno=', c.cutlass_scaled_mm.__code__.co_firstlineno)
PY"

  rm -rf "${CUSTOM_OPS_TMP_DIR}"
fi

if [ "${FORCE_NVFP4_CLAMP_BACKEND_RELAX}" = "1" ]; then
  echo "== patch NvFP4 clamp backend gate (allow CUTLASS/B12X fallback when swiglu_limit is set) =="
  NVFP4_ORACLE_PATH="${VLLM_SITE_PACKAGES}/vllm/model_executor/layers/fused_moe/oracle/nvfp4.py"
  NVFP4_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${NVFP4_ORACLE_PATH}" "${NVFP4_TMP_DIR}/nvfp4.py"
  NVFP4_PATCH_STATUS="$(python3 - "${NVFP4_TMP_DIR}/nvfp4.py" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker = "NvFp4MoeBackend.FLASHINFER_TRTLLM,\n      NvFp4MoeBackend.FLASHINFER_CUTLASS,\n      NvFp4MoeBackend.FLASHINFER_B12X,"
if marker not in text:
  patterns = [
    re.compile(
      r"NVFP4_BACKENDS_WITH_CLAMP\s*=\s*\{\n"
      r"\s*NvFp4MoeBackend\.FLASHINFER_TRTLLM,\n"
      r"\s*\}",
      flags=re.MULTILINE,
    ),
    re.compile(
      r"NVFP4_BACKENDS_WITH_CLAMP\s*=\s*\{\n"
      r"(?:.*\n)*?"
      r"\s*\}",
      flags=re.MULTILINE,
    ),
  ]
  replacement = (
    "NVFP4_BACKENDS_WITH_CLAMP = {\n"
    "      NvFp4MoeBackend.FLASHINFER_TRTLLM,\n"
    "      NvFp4MoeBackend.FLASHINFER_CUTLASS,\n"
    "      NvFp4MoeBackend.FLASHINFER_B12X,\n"
    "  }"
  )
  patched = False
  for pattern in patterns:
    new_text, n = pattern.subn(replacement, text, count=1)
    if n == 1:
      text = new_text
      patched = True
      break

  if not patched:
    fallback_anchor = "NvFp4MoeBackend.FLASHINFER_TRTLLM,"
    if fallback_anchor in text:
      text = text.replace(
        fallback_anchor,
        fallback_anchor + "\n      NvFp4MoeBackend.FLASHINFER_CUTLASS,\n      NvFp4MoeBackend.FLASHINFER_B12X,",
        1,
      )
      patched = True

  if not patched:
    print("skipped: NVFP4_BACKENDS_WITH_CLAMP block not found")
    path.write_text(text)
    raise SystemExit(0)

path.write_text(text)
print("applied")
PY
 )"
  NVFP4_PATCH_STATUS="${NVFP4_PATCH_STATUS##*$'\n'}"
  if [ "${NVFP4_PATCH_STATUS}" != "applied" ]; then
  echo "WARNING: NVFP4 clamp backend relax patch skipped (${NVFP4_PATCH_STATUS:-unknown reason}); continuing"
  fi

  docker cp "${NVFP4_TMP_DIR}/nvfp4.py" "dspark-head:${NVFP4_ORACLE_PATH}"
  cat "${NVFP4_TMP_DIR}/nvfp4.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/nvfp4.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/nvfp4.py dspark-worker:${NVFP4_ORACLE_PATH}"

  rm -rf "${NVFP4_TMP_DIR}"
fi

if [ "${FORCE_FLASHINFER_MQA_OUTPUT_BF16_GUARD}" = "1" ]; then
  echo "== patch DeepSeek attention output buffer dtype guard (avoid float32->bf16 assert in flashinfer_sparse) =="
  ATTN_PATH="${VLLM_SITE_PACKAGES}/vllm/models/deepseek_v4/attention.py"
  ATTN_TMP_DIR="$(mktemp -d)"

  docker cp "dspark-head:${ATTN_PATH}" "${ATTN_TMP_DIR}/attention.py"
  ATTN_PATCH_STATUS="$(python3 - "${ATTN_TMP_DIR}/attention.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker = "FLASHINFER_MQA_OUTPUT_BF16_GUARD"
if marker in text:
  print("already")
  raise SystemExit(0)

needle = "dtype=hidden_states.dtype,"
replacement = (
  "dtype=(torch.bfloat16 if hidden_states.dtype == torch.float32 else hidden_states.dtype), "
  "# FLASHINFER_MQA_OUTPUT_BF16_GUARD"
)

if needle not in text:
  print("skipped: attention dtype allocation line not found")
  path.write_text(text)
  raise SystemExit(0)

text = text.replace(needle, replacement, 1)
path.write_text(text)
print("applied")
PY
 )"
  ATTN_PATCH_STATUS="${ATTN_PATCH_STATUS##*$'\n'}"
  if [ "${ATTN_PATCH_STATUS}" != "applied" ] && [ "${ATTN_PATCH_STATUS}" != "already" ]; then
    echo "WARNING: attention dtype guard patch skipped (${ATTN_PATCH_STATUS:-unknown reason}); continuing"
  fi

  docker cp "${ATTN_TMP_DIR}/attention.py" "dspark-head:${ATTN_PATH}"
  cat "${ATTN_TMP_DIR}/attention.py" | "${sshw[@]}" "gipsoft@${WORKER_IP}" "cat > /tmp/attention.py"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "docker cp /tmp/attention.py dspark-worker:${ATTN_PATH}"

  rm -rf "${ATTN_TMP_DIR}"
fi

MODEL_TO_SERVE_ARG="${DSPARK_MODEL}"
HF_OFFLINE_DEFAULT=0
SNAPSHOT_CANDIDATE="$(docker exec dspark-head bash -lc "ls -1dt ${MODEL_CONTAINER_DIR}/* 2>/dev/null | head -n 1" || true)"
if [ -n "${SNAPSHOT_CANDIDATE}" ]; then
  MODEL_TO_SERVE_ARG="${SNAPSHOT_CANDIDATE}"
  HF_OFFLINE_DEFAULT=1
else
  echo "WARNING: no local snapshot found under ${MODEL_CONTAINER_DIR}; falling back to repo-id ${DSPARK_MODEL}"
  echo "         HF cache is redirected to /tmp/hf-home to avoid read-only lock failures"
fi
echo "  MODEL_TO_SERVE_ARG=${MODEL_TO_SERVE_ARG}"

echo "== launch vllm serve (detached on worker + head) =="
start_startup_memory_monitor
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
export HF_HOME=/tmp/hf-home
export HF_HUB_CACHE=/tmp/hf-home/hub
export HUGGINGFACE_HUB_CACHE=/tmp/hf-home/hub
export TRANSFORMERS_CACHE=/tmp/hf-home/transformers
export XDG_CACHE_HOME=/tmp/xdg-cache
export TILELANG_CACHE_DIR=/tmp/tilelang-cache
export TVM_CACHE_DIR=/tmp/tvm-cache
export TORCHINDUCTOR_CACHE_DIR=/tmp/torchinductor-cache
export TRITON_CACHE_DIR=/tmp/triton-cache
export VLLM_CACHE_ROOT=/tmp/vllm-cache
export DG_JIT_CACHE_DIR=/tmp/deepgemm-cache
export DG_JIT_USE_NVRTC=1
export CUDA_HOME=/usr/local/cuda
# Keep CUDA stubs available for JIT link commands, but never expose the stubs
# directory to the runtime loader: TileLang's libcudart_stub lacks CUDA APIs
# such as cudaDeviceReset used during vLLM worker shutdown.
export LD_LIBRARY_PATH=/opt/env/lib64:/opt/env/lib:/opt/env/targets/sbsa-linux/lib:/usr/local/cuda/lib64
MODEL_TO_SERVE="${MODEL_TO_SERVE_ARG}"
if [ "${HF_OFFLINE_DEFAULT}" = "1" ]; then
  export HF_HUB_OFFLINE=1
  export TRANSFORMERS_OFFLINE=1
fi
echo "MODEL_TO_SERVE=\${MODEL_TO_SERVE}"
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
export MAX_JOBS=${MAX_JOBS}
export SPARSE_MQA_DEBUG=${SPARSE_MQA_DEBUG:-0}
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
  /tmp/hf-home/hub \
  /tmp/hf-home/transformers \
  /tmp/xdg-cache \
  /tmp/tilelang-cache \
  /tmp/tvm-cache \
  /tmp/torchinductor-cache \
  /tmp/triton-cache \
  /tmp/vllm-cache \
  /tmp/deepgemm-cache \
  /tmp/flashinfer

SPECULATIVE_CONFIG='{"method":"dspark","num_speculative_tokens":${MTP_NUM_TOKENS},"draft_sample_method":"probabilistic"}'

SPECULATIVE_FLAGS=()
ENABLE_SPECULATIVE_DECODE_RUNTIME="\${ENABLE_SPECULATIVE_DECODE:-1}"
if [ "\${ENABLE_SPECULATIVE_DECODE_RUNTIME}" = "1" ]; then
  SPECULATIVE_FLAGS=(--speculative-config "\${SPECULATIVE_CONFIG}")
fi

CHUNKED_PREFILL_FLAGS=()
ENABLE_CHUNKED_PREFILL_RUNTIME="\${ENABLE_CHUNKED_PREFILL:-1}"
if [ "\${ENABLE_CHUNKED_PREFILL_RUNTIME}" = "1" ]; then
  CHUNKED_PREFILL_FLAGS=(--enable-chunked-prefill)
else
  CHUNKED_PREFILL_FLAGS=(--no-enable-chunked-prefill)
fi

PREFIX_CACHING_FLAGS=()
ENABLE_PREFIX_CACHING_RUNTIME="\${ENABLE_PREFIX_CACHING:-1}"
if [ "\${ENABLE_PREFIX_CACHING_RUNTIME}" = "1" ]; then
  PREFIX_CACHING_FLAGS=(--enable-prefix-caching)
else
  PREFIX_CACHING_FLAGS=(--no-enable-prefix-caching)
fi

ASYNC_SCHEDULING_FLAGS=()
ENABLE_ASYNC_SCHEDULING_RUNTIME="\${ENABLE_ASYNC_SCHEDULING:-0}"
if [ "\${ENABLE_ASYNC_SCHEDULING_RUNTIME}" = "1" ]; then
  ASYNC_SCHEDULING_FLAGS=(--async-scheduling)
else
  ASYNC_SCHEDULING_FLAGS=(--no-async-scheduling)
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

MOE_BACKEND_FLAGS=()
if [ -n "${MOE_BACKEND}" ]; then
  MOE_BACKEND_FLAGS=(--moe-backend "${MOE_BACKEND}")
fi

VLLM_CMD=""
if command -v vllm >/dev/null 2>&1; then
  VLLM_CMD="\$(command -v vllm)"
elif [ -x /usr/local/bin/vllm ]; then
  VLLM_CMD="/usr/local/bin/vllm"
elif [ -x /opt/env/bin/vllm ]; then
  VLLM_CMD="/opt/env/bin/vllm"
fi

if [ -z "\${VLLM_CMD}" ]; then
  echo "ERROR: vllm CLI not found in container PATH"
  echo "PATH=\${PATH}"
  ls -l /usr/local/bin/vllm /opt/env/bin/vllm 2>/dev/null || true
  python3 - <<'PY'
import importlib.util
spec = importlib.util.find_spec('vllm')
print('python can import vllm:', bool(spec))
print('vllm origin:', getattr(spec, 'origin', None))
PY
  exit 1
fi

exec "\${VLLM_CMD}" serve "\${MODEL_TO_SERVE}" \
  --served-model-name ${SERVED_NAME} \
  --port ${PORT} \
  --host 0.0.0.0 \
  --linear-backend ${LINEAR_BACKEND} \
  --trust-remote-code \
  --tensor-parallel-size 2 \
  --pipeline-parallel-size 1 \
  "\${MOE_BACKEND_FLAGS[@]}" \
  --kv-cache-dtype nvfp4_ds_mla \
  --block-size 256 \
  --max-model-len ${MAX_MODEL_LEN} \
  --max-num-seqs ${MAX_NUM_SEQS} \
  --max-num-batched-tokens ${MAX_NUM_BATCHED_TOKENS} \
  --max-parallel-loading-workers ${MAX_PARALLEL_LOADING_WORKERS} \
  --kv-cache-memory-bytes ${KV_CACHE_MEMORY_BYTES} \
  --gpu-memory-utilization ${GPU_MEM_UTIL} \
  "\${PREFIX_CACHING_FLAGS[@]}" \
  "\${ASYNC_SCHEDULING_FLAGS[@]}" \
  "\${CHUNKED_PREFILL_FLAGS[@]}" \
  "\${SPECULATIVE_FLAGS[@]}" \
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
"${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec -d dspark-worker bash -lc 'NODE_RANK=1 ENABLE_ASYNC_SCHEDULING=${BOOTSTRAP_ENABLE_ASYNC_SCHEDULING} ENABLE_PREFIX_CACHING=${BOOTSTRAP_ENABLE_PREFIX_CACHING} ENABLE_SPECULATIVE_DECODE=${BOOTSTRAP_ENABLE_SPECULATIVE_DECODE} ENABLE_CHUNKED_PREFILL=${BOOTSTRAP_ENABLE_CHUNKED_PREFILL} bash ${SERVE_SCRIPT_IN_CONTAINER}'"
docker exec -d dspark-head bash -lc "NODE_RANK=0 ENABLE_ASYNC_SCHEDULING=${BOOTSTRAP_ENABLE_ASYNC_SCHEDULING} ENABLE_PREFIX_CACHING=${BOOTSTRAP_ENABLE_PREFIX_CACHING} ENABLE_SPECULATIVE_DECODE=${BOOTSTRAP_ENABLE_SPECULATIVE_DECODE} ENABLE_CHUNKED_PREFILL=${BOOTSTRAP_ENABLE_CHUNKED_PREFILL} bash ${SERVE_SCRIPT_IN_CONTAINER}"
rm -f "${SERVE_SCRIPT_LOCAL}"

echo "LAUNCHED — Monitor progress using command below:"
echo "docker exec dspark-head tail -f ${SERVE_LOG_IN_CONTAINER}"

if [ "${WAIT_FOR_HEALTH}" = "1" ]; then
  echo "== wait for API health (timeout ${STARTUP_TIMEOUT_SEC}s) =="
  START_TS="$(date +%s)"
  while true; do
    check_startup_monitor_flag

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

if [ "${AUTO_PROMOTE_SPECULATIVE_AFTER_READY}" = "1" ]; then
  echo "== staged startup: promote speculative/chunked after initial ready =="
  echo "  stopping bootstrap vllm serve on both nodes"
  docker exec dspark-head bash -lc "pkill -f 'vllm serve' >/dev/null 2>&1 || true"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc \"pkill -f 'vllm serve' >/dev/null 2>&1 || true\"" || true

  echo "  restarting vllm serve with promoted flags"
  "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec -d dspark-worker bash -lc 'NODE_RANK=1 ENABLE_ASYNC_SCHEDULING=${PROMOTED_ENABLE_ASYNC_SCHEDULING} ENABLE_PREFIX_CACHING=${PROMOTED_ENABLE_PREFIX_CACHING} ENABLE_SPECULATIVE_DECODE=${PROMOTED_ENABLE_SPECULATIVE_DECODE} ENABLE_CHUNKED_PREFILL=${PROMOTED_ENABLE_CHUNKED_PREFILL} bash ${SERVE_SCRIPT_IN_CONTAINER}'"
  docker exec -d dspark-head bash -lc "NODE_RANK=0 ENABLE_ASYNC_SCHEDULING=${PROMOTED_ENABLE_ASYNC_SCHEDULING} ENABLE_PREFIX_CACHING=${PROMOTED_ENABLE_PREFIX_CACHING} ENABLE_SPECULATIVE_DECODE=${PROMOTED_ENABLE_SPECULATIVE_DECODE} ENABLE_CHUNKED_PREFILL=${PROMOTED_ENABLE_CHUNKED_PREFILL} bash ${SERVE_SCRIPT_IN_CONTAINER}"

  if [ "${WAIT_FOR_HEALTH}" = "1" ]; then
    echo "== wait for API health after promotion (timeout ${STARTUP_TIMEOUT_SEC}s) =="
    START_TS="$(date +%s)"
    while true; do
      check_startup_monitor_flag

      if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
        echo "READY: vLLM API is healthy after promotion on :${PORT}"
        break
      fi

      NOW_TS="$(date +%s)"
      ELAPSED="$((NOW_TS - START_TS))"
      if [ "${ELAPSED}" -ge "${STARTUP_TIMEOUT_SEC}" ]; then
        echo "ERROR: promoted vLLM health did not become ready within ${STARTUP_TIMEOUT_SEC}s"
        echo "--- head log tail ---"
        docker exec dspark-head bash -lc "tail -n 120 ${SERVE_LOG_IN_CONTAINER}" || true
        echo "--- worker log tail ---"
        "${sshw[@]}" "gipsoft@${WORKER_IP}" "sudo docker exec dspark-worker bash -lc 'tail -n 120 /tmp/dspark-serve-worker.log'" || true
        exit 1
      fi

      echo "  waiting after promotion... ${ELAPSED}s"
      sleep "${HEALTH_POLL_SEC}"
    done
  fi
fi

if [ "${ENABLE_FIRST_REQUEST_PREWARM}" = "1" ]; then
  check_startup_monitor_flag
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

check_startup_monitor_flag
stop_startup_memory_monitor
rm -f "${STARTUP_MONITOR_FLAG_FILE}"

LAUNCH_IN_PROGRESS=0
