# DeepSeek V4 Flash 0731 Rarri NVFP4 Handoff

> Dated 2026-08-11. This document is a restart point for a future chat or a newer runtime/patch stack. It records the verified state, failed experiments, and the current numerical-correctness blocker.

## Executive Summary

The dual-node vLLM deployment boots successfully and exposes an OpenAI-compatible API, but generated text is cryptic even with greedy decoding. The API and VS Code provider are not the cause.

Current conclusion:

```text
Rarri mixed FP8/NVFP4 checkpoint loads successfully,
but the current Anemll/vLLM image plus compatibility fallbacks
produces numerically invalid logits.
```

The strongest diagnostic result is from the sparse indexer fallback:

```text
SPARSE_MQA_DEBUG unpaged
q (16, 64, 128) torch.float8_e4m3fn
k (4, 128) torch.float8_e4m3fn
weights (16, 64) torch.float32
logits (16, 4) torch.float32
finite_logits 32 / 64
finite_logits_range (0.0, 0.0)
nonzero_logits 0
```

This means every finite valid unpaged sparse-indexer logit observed during warmup was exactly zero. The generated responses are consequently nonsensical and may continue until `max_tokens` instead of producing EOS.

## Cluster

| Role | Host | Fabric IP |
|---|---|---|
| Head | `aitopatom-ad9e` | `192.168.100.10` |
| Worker | `aitopatom-ad9f` | `192.168.100.11` |

- Remote debugging host: `ssh gipsoft@aitopatom-ad9e`
- Head container: `dspark-head`
- Worker container is on the worker host, not the head host.
- API endpoint from the workstation: `http://100.66.8.46:8888/v1`
- API endpoint inside the head node: `http://127.0.0.1:8888/v1`
- Served model: `deepseek-v4-flash-dspark`
- Internal rendezvous: `192.168.100.10:25000`

## Model And Image

### Active checkpoint

```text
Rarri/DeepSeek-V4-Flash-0731-NVFP4
```

Cached snapshot:

```text
/cache/huggingface/hub/models--Rarri--DeepSeek-V4-Flash-0731-NVFP4/snapshots/a2456e5a5f33fac740024745ccf0811974969d25
```

Verified metadata:

```text
architecture: DeepseekV4ForCausalLM
torch_dtype: bfloat16
producer: modelopt
producer version: dsv4-nvfp4-experts-mtp-fallback
quant_method: fp8
quant_algo: MIXED_PRECISION
moe_quant_algo: NVFP4
format: e4m3
group_size: 16
```

Important: this is a mixed-precision ModelOpt conversion. The expert layers are NVFP4, while attention, shared experts, and the head are listed in the checkpoint's `ignore` metadata. It is not a generic fully-NVFP4 checkpoint.

### Active image

```text
ghcr.io/anemll/dspark-vllm-gx10:0.1.1-ray
```

Runtime:

```text
vLLM 0.25.2.dev0+g752a3a504.d20260714
Python 3.12
```

The image has a usable compiler at:

```text
/usr/local/cuda/bin/nvcc
```

The launcher must use:

```text
CUDA_HOME=/usr/local/cuda
```

Using `CUDA_HOME=/opt/env` caused FlashInfer/TileLang to invoke a nonexistent `/opt/env/bin/nvcc`.

## Known-Good Boot Profile

This profile boots the engine, completes sparse MLA warmup, and serves `/health` and `/v1/models`:

```bash
sudo \
  IMAGE=ghcr.io/anemll/dspark-vllm-gx10:0.1.1-ray \
  RAY_RUNTIME_INSTALL=0 \
  DSPARK_MODEL=Rarri/DeepSeek-V4-Flash-0731-NVFP4 \
  RARRI_NVFP4_TUNE_AUTO=1 \
  RARRI_ULTRA_SAFE_MODE=1 \
  RARRI_FORCE_NVFP4_CLAMP_RELAX=1 \
  AUTO_PROMOTE_SPECULATIVE_AFTER_READY=0 \
  ENABLE_SPECULATIVE_DECODE=0 \
  ENABLE_CHUNKED_PREFILL=1 \
  ENABLE_PREFIX_CACHING=0 \
  ENABLE_ASYNC_SCHEDULING=0 \
  FORCE_MHC_TORCH_FALLBACK=0 \
  FORCE_DISABLE_DEEP_GEMM_ON_INVALID_IMAGE=1 \
  FORCE_DISABLE_DEEP_GEMM_MQA_METADATA=1 \
  FORCE_DISABLE_DEEP_GEMM_SPARSE_INDEXER=1 \
  FORCE_DSPARK_WO_FALLBACK=1 \
  FORCE_DEEP_GEMM_SM121_COMPAT=1 \
  FORCE_NVFP4_CLAMP_BACKEND_RELAX=1 \
  MOE_BACKEND=flashinfer_cutlass \
  SPARSE_MQA_DEBUG=1 \
  bash ./scripts/my-deepseekV4Flash-launch.sh
```

Effective safe profile after `RARRI_ULTRA_SAFE_MODE=1`:

```text
MAX_MODEL_LEN=65536
MAX_NUM_SEQS=1
MAX_NUM_BATCHED_TOKENS=128
MAX_PARALLEL_LOADING_WORKERS=1
GPU_MEM_UTIL=0.45
KV_CACHE_MEMORY_BYTES=4000000000
ENABLE_SPECULATIVE_DECODE=0
ENABLE_CHUNKED_PREFILL=1
ENABLE_PREFIX_CACHING=0
ENABLE_ASYNC_SCHEDULING=0
```

The launcher has a direct default of `FORCE_MHC_TORCH_FALLBACK=0` for the current A/B experiment. Set it to `1` only when intentionally testing the torch MHC fallback.

## What Has Been Proven

### API and provider

Direct curl requests work at the protocol level:

```text
GET /health -> 200
GET /v1/models -> 200
POST /v1/chat/completions -> 200
```

The VS Code endpoint is:

```text
http://100.66.8.46:8888/v1
```

Greedy decoding also produces cryptic output, so this is not a temperature/top-p or builtin-provider issue.

### Model loading

The model loads successfully and uses about:

```text
77.79 GiB GPU memory per rank
```

### Sparse MLA warmup

With `CUDA_HOME=/usr/local/cuda`, FlashInfer sparse MLA JIT compilation succeeds. Earlier failures at `/opt/env/bin/nvcc` were a CUDA_HOME path problem, not a model-memory problem.

### Native MHC A/B experiment

Native MHC TileLang compiled successfully when `FORCE_MHC_TORCH_FALLBACK=0`, but output remained cryptic. Therefore the MHC torch fallback is not the only cause.

### Sparse MQA owner path

The sparse indexer imports MQA functions directly from:

```text
vllm.utils.deep_gemm
```

The earlier patch to `sparse_attn_indexer.py` was ineffective for this call path. The actual owner dispatcher is patched by the launcher with a versioned shim.

## Current Patch Stack

The active launcher is:

```text
scripts/my-deepseekV4Flash-launch.sh
```

It applies many compatibility changes. The most relevant ones are:

- `DEEP_GEMM_MQA_TORCH_FALLBACK_SHIM_V6` or newer: owner-level unpaged MQA torch fallback; current experiment removes `score.relu()` because the previous version collapsed valid logits to zero.
- `DEEP_GEMM_MQA_TORCH_FALLBACK_SHIM_V5` diagnostics: finite-only logit range and nonzero count. The launcher may currently contain a later version; inspect the marker before relying on this text.
- `SAMPLER_CORE_LOGITS_RANK_SHIM_V1`: normalizes higher-rank logits before greedy and random sampling.
- `FLASHINFER_SAMPLER_RANK_FALLBACK_SHIM_V9`: last-position handling for higher-rank sampler logits.
- Native MHC path is currently selected with `FORCE_MHC_TORCH_FALLBACK=0`.
- `FLASHINFER_SPARSE_WO_EINSUM_FALLBACK_SHIM_V2`: sparse WO fallback in `flashinfer_sparse.py`.
- Cutlass scaled-MM fallback shim.
- Attention output BF16 guard.
- FlashInfer Cutlass MoE init ABI retry for 7-versus-8 arguments.
- `CUDA_HOME=/usr/local/cuda` and `/usr/local/cuda/bin/nvcc` preflight.

The launcher output must be treated as the authority for the exact current marker versions.

## Known Failures And Root Causes

### 1. Cutlass scaled-MM failure

Original failure was a Cutlass C++ stride/alignment precondition. A generic Python fallback was not sufficient for packed FP8 block-scaled layouts. A versioned Cutlass shim was added for startup survival.

### 2. DeepGEMM MQA invalid image

Original failure:

```text
CUDA_ERROR_INVALID_IMAGE
```

The image's DeepGEMM kernels are not usable for this SM121/GB10 path. DeepGEMM is disabled with:

```text
VLLM_USE_DEEP_GEMM=0
```

The owner-level MQA fallback is required to prevent direct imports from reactivating the DeepGEMM dispatcher.

### 3. TileLang/NVCC path

The image contains `/usr/local/cuda/bin/nvcc`, not `/opt/env/bin/nvcc`. All JIT paths must use `/usr/local/cuda` as `CUDA_HOME`.

### 4. MHC TileLang dtype assertion

Native MHC initially failed on dtype assertions. Torch fallbacks were added for pre/post/head operations. Native MHC later compiled successfully but did not fix cryptic output.

### 5. Sampler rank and output shape failures

Higher-rank logits caused FlashInfer/native sampler failures and later greedy/random shape mismatches. Core sampler normalization and last-position selection were added. These fixed crashes, not numerical corruption.

### 6. Current numerical correctness failure

Direct deterministic responses remain cryptic, for example:

```text
学习集格外 Didžiulis格外 KLIMA珍惜ulata学习集ulata也称夥ulataaghraud截然Smallest
```

and:

```text
acre嫌弃更正)!臆也应该赫然也应该)!也应该也应该尊优先级震慑惜重温
```

The current strongest evidence is:

```text
finite_logits_range (0.0, 0.0)
nonzero_logits 0
```

for valid unpaged sparse-indexer logits during warmup. This indicates that the torch MQA fallback is collapsing the valid indexer logits.

Removing ReLU did not restore coherent output. Native MHC also did not restore coherent output.

## Current Interpretation

The current deployment is operational but not numerically correct:

```text
API works; model output is invalid.
```

Do not treat `/health`, model loading, or HTTP 200 as proof of correctness.

The Rarri checkpoint is not obviously the wrong model. It is a specialized ModelOpt mixed FP8/NVFP4 conversion. The blocker is the missing compatible sparse MQA/indexer path in the current runtime, combined with multiple fallback operations.

Do not download another random NVFP4 model as the next step. Another NVFP4 conversion may use a different packing/scale contract and will not isolate the current failure.

## Recommended Next Steps

### A. Capture the V5/V6 diagnostic from a fresh restart

On the next launch, confirm the owner shim marker in the console and capture:

```text
SPARSE_INDEXER_BACKEND=TORCH
DEEP_GEMM_MQA_OWNER_V*_HEAD_ACTIVE
DEEP_GEMM_MQA_OWNER_V*_WORKER_ACTIVE
SPARSE_MQA_DEBUG unpaged ...
SPARSE_MQA_DEBUG paged ...
```

The worker log is on the worker host, not the head host:

```bash
ssh gipsoft@aitopatom-ad9e \
  "sudo docker exec dspark-worker grep -n SPARSE_MQA_DEBUG /tmp/dspark-serve-worker.log"
```

### B. Run a clean FP8 baseline

The most valuable A/B is the original FP8 checkpoint with the matching runtime/overlay, not another NVFP4 conversion:

```text
deepseek-ai/DeepSeek-V4-Flash-0731
```

The `coolbho3k/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark` repository documents this original checkpoint as FP8 and uses a more complete 0731 overlay/runtime. A coherent FP8 result would implicate the Rarri conversion/fallback path.

### C. Compare against the newer repository

The newer repository documents:

- Original `deepseek-ai/DeepSeek-V4-Flash-0731`
- FP8 weights
- Anemll-derived custom runtime overlay
- 1M context profile
- DeepSeek-specific encoder/reasoning compatibility
- MHC and sparse MLA implementation changes

Do not copy its 1M memory settings directly into this Rarri experiment. First reproduce its checkpoint/runtime pair.

### D. If staying with Rarri NVFP4

The missing piece is a correct SM121-compatible sparse MQA/indexer implementation for this ModelOpt checkpoint. A future vLLM/Anemll runtime may provide it. The current torch fallback should not be considered numerically valid merely because it boots.

## Direct API Test

Use deterministic decoding:

```bash
curl -sS --max-time 120 \
  http://100.66.8.46:8888/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-v4-flash-dspark",
    "messages": [
      {"role": "user", "content": "Hello, which LLM are you? Reply in one short sentence."}
    ],
    "max_tokens": 16,
    "temperature": 0.0,
    "top_p": 1.0,
    "stream": false
  }'
```

A valid HTTP response is not enough. The content must be coherent.

## Files Changed During This Work

- `scripts/my-deepseekV4Flash-launch.sh`
  - Extensive runtime compatibility and diagnostic patches.
- `scripts/vllm-deepseekV4Flash.service`
  - Updated stable Anemll/Rarri profile and post-start chat probe.
- `~/.config/Code - Insiders/User/chatLanguageModels.json`
  - Endpoint changed to `http://100.66.8.46:8888/v1`.
- `~/.config/Code - Insiders/User/settings.json`
  - Matching OpenAI-compatible endpoint and model limits.

The user configuration files are outside this repository and should be checked independently in a future session.

## Fresh-Chat Opening Prompt

Use this summary to start a future debugging chat:

> We have a dual-DGX-Spark TP=2 vLLM deployment using `ghcr.io/anemll/dspark-vllm-gx10:0.1.1-ray` and `Rarri/DeepSeek-V4-Flash-0731-NVFP4`. The engine boots and HTTP works, but deterministic output is cryptic. The checkpoint metadata is ModelOpt mixed FP8/NVFP4 (`producer=dsv4-nvfp4-experts-mtp-fallback`, `moe_quant_algo=NVFP4`, `group_size=16`, attention ignored). The strongest diagnostic is `SPARSE_MQA_DEBUG unpaged ... finite_logits_range (0.0, 0.0) nonzero_logits 0` from the owner-level torch fallback in `vllm/utils/deep_gemm.py`; removing ReLU and switching native MHC did not fix output. Do not make broad fallback changes. First inspect the live owner shim, compare the torch MQA formula/scale interpretation with the canonical DeepGEMM reference, and run a clean FP8 `deepseek-ai/DeepSeek-V4-Flash-0731` A/B if available.
