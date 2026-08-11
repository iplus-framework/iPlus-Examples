# DeepSeek-V4-Flash-0731 on 2x DGX Spark — Deployment Handoff

> Copy this entire file into a new chat with another LLM (e.g. GitHub Copilot) to
> continue the work of bringing up DeepSeek-V4-Flash-0731 on a dual DGX Spark cluster.

---

## Goal

Serve `deepseek-ai/DeepSeek-V4-Flash-0731` (NVFP4, ~167 GB) across two NVIDIA DGX
Spark (GB10) nodes at TP=2 using vLLM with DSpark speculative decoding and the
`nvfp4_ds_mla` KV cache. The model is already downloaded; the runtime image and
launch orchestration are set up. This document describes the current state and the
next steps.

---

## Cluster topology

| Node | Hostname (Tailscale) | Role | Internal IP (RoCE fabric) |
|------|----------------------|------|---------------------------|
| Node 1 | `aitopatom-ad9e` | Head (Ray head + vLLM serve) | `192.168.100.10` |
| Node 2 | `aitopatom-ad9f` | Worker (Ray worker) | `192.168.100.11` |

- SSH from your workstation: `ssh gipsoft@aitopatom-ad9e` (password prompt).
- The internal `192.168.100.x` network is **not** reachable remotely — only via the
  Tailscale hostnames. The nodes reach each other over `192.168.100.x` for Ray/NCCL.
- SSH key for node-to-node (head → worker) is `/home/gipsoft/.ssh/id_ed25519_shared`.
- User on both nodes: `gipsoft`.

---

## Current state (verified 2026-08-08)

| Item | Status |
|------|--------|
| Model weights | ✅ Present on **both** nodes at `/home/gipsoft/.cache/huggingface/hub/models--deepseek-ai--DeepSeek-V4-Flash-0731` |
| Runtime image | ❌ **Missing on both nodes** — must be obtained (see below) |
| Launch script | ✅ `scripts/my-deepseekV4Flash-launch.sh` (mirrored to both nodes) |
| systemd service | ✅ `scripts/vllm-deepseekV4Flash.service` (mirrored to both nodes) |
| Patch 4 | ✅ `patches/0004-dspark-shared-expert-gate-up-proj.patch` present in repo |

The launch script defaults to image `vllm-dspark-runtime:dspark-nvfp4-stage-c`
(Option A). If you use the Anemll prebuilt image instead, set
`IMAGE=ghcr.io/anemll/dspark-vllm-gx10:0.1.1` when launching.

---

## Next steps

### Step 1 — Get the runtime image (REQUIRED, both nodes)

**Option A: Build locally (self-contained, slower):**
```bash
# On BOTH nodes:
cd ~/github/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark
./build-dspark-vllm-runtime.sh
```
This builds `vllm-dspark-runtime:dspark-nvfp4-stage-c`.

**Option B: Pull prebuilt Anemll image (simpler, recommended):**
```bash
# On BOTH nodes:
docker pull ghcr.io/anemll/dspark-vllm-gx10:0.1.1
```
If using this, launch with `IMAGE=ghcr.io/anemll/dspark-vllm-gx10:0.1.1 \
bash scripts/my-deepseekV4Flash-launch.sh` (the script reads the `IMAGE` env var).

> Note: the Anemll image may not register every `VLLM_DSPARK_*` / `VLLM_USE_B12X_*`
> env var (they're no-ops there). The critical speed flag `VLLM_USE_B12X_MOE=1`
> is handled inside the image. The launch script already sets the important ones.

### Step 2 — Verify the model is complete on both nodes
```bash
# On both nodes:
ls /home/gipsoft/.cache/huggingface/hub/models--deepseek-ai--DeepSeek-V4-Flash-0731/snapshots
# Should show a snapshot directory with config.json + safetensors shards.
```

### Step 3 — Launch (from head node, `aitopatom-ad9e`)
```bash
cd ~/github/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark
# Optionally override the image:
export IMAGE=ghcr.io/anemll/dspark-vllm-gx10:0.1.1   # if using Option B
bash scripts/my-deepseekV4Flash-launch.sh
```

### Step 4 — Monitor
```bash
docker exec dspark-head tail -f /tmp/dspark-serve.log
# Wait for "Application startup complete"
curl http://127.0.0.1:8888/v1/models
```

---

## Key configuration (already in the script)

| Flag | Value | Why |
|------|-------|-----|
| `--kv-cache-dtype nvfp4_ds_mla` | NVFP4 MLA KV | 4-bit KV, ~half bytes/token vs fp8 |
| `--max-model-len` | `1048576` | 1M = true YaRN ceiling |
| `--max-num-seqs` | `6` | Avoids issue-#8 first-request OOM |
| `--gpu-memory-utilization` | `0.78` | 0.85 triggers OOM on real traffic |
| `--kv-cache-memory-bytes` | `24000000000` | Pins KV pool (removes non-deterministic profiler) |
| `--speculative-config` | `{"method":"dspark","num_speculative_tokens":5,...}` | k=5 locked ( .drafter emits 5 tokens/pass) |
| `--compilation-config` | cudagraph ladder `[2,4,6,12,24,48,72,96,144]` | Multiples of 6 for k=5 spec decode |

---

## Troubleshooting

- **`World size (2) larger than available GPUs (1)`** — multi-node vLLM needs
  `--distributed-executor-backend mp` (the script sets this).
- **Low throughput (<20 tok/s)** — Patch 4 not applied, or draft MoE backend wrong.
  The script applies Patch 4 automatically from `patches/`.
- **First request after boot is slow (~30%)** — this is normal warm-up; send a few
  real requests before benchmarking.
- **OOM on first real request** — lower `GPU_MEM_UTIL` to `0.75` or reduce `MAX_NUM_SEQS`.

---

## Files of interest

- `scripts/my-deepseekV4Flash-launch.sh` — the orchestrator (Ray head + worker, then vLLM serve)
- `scripts/vllm-deepseekV4Flash.service` — systemd unit (head node)
- `patches/0004-dspark-shared-expert-gate-up-proj.patch` — DSpark draft loader fix for 0731
- `README.md` — full project documentation (tonyd2wild's repo)
- `docker-compose.dspark.yml` — alternative (compose-based) launch, if you prefer that over the script

---

## What was already done (for context)

- Model downloaded to both nodes.
- Repo mirrored from a local working copy to `~/github/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark` on both nodes.
- Custom launch script + service file created and placed in the repo's `scripts/`.
- Script updated with "best of all" settings from community recipes (tonyd2wild sparkrun,
  3.23x1M, MiaAI-Lab, dgx-spark-2).
