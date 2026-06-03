# How To Guide: Deploying and Configuring LLMs via vLLM with NVIDIA GPUs

This guide summarizes setup instructions for running different language models using vLLM services, focusing on systemd service files and IDE configuration settings found in the provided notes.

---

## 🧠 Model Overviews & Use Cases

### Qwen3.6-35B-A3B (Fast Agentic Tasks)
*   **Best For**: Fast agentic tasks where complexity is lower.
*   **Note**: Explicitly stated as *not suitable for complex coding tasks*.

### Qwen3.6-27B (Complex Coding Tasks)
*   **Best For**: Slower but more complex coding tasks.

---

## ⚙️ Systemd Service Configuration Examples (Linux/Docker Deployment)

The following examples show how to create a `systemd` service file for running the vLLM server using Docker. These files should be placed in `/etc/systemd/system/vllm-*.service`.

### A. Service for Qwen3.6-35B-A3B Model
Use this configuration when deploying the model intended for fast agentic tasks (e.g., `Qwen/Qwen3.6-35B-A3B` tokenizer).

**File Location Example**: `/etc/systemd/system/vllm-qwen3.service`

```ini
[Unit]
Description=NVIDIA vLLM Qwen3.6-35B-A3B Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
Environment="VLLM_SLEEP_WHEN_IDLE=1"
Environment="HF_HOME=/root/.cache/huggingface"

# Override NVIDIA Container Runtime cgroup restrictions
Environment="NVIDIA_VISIBLE_DEVICES=all"
Environment="NVIDIA_DRIVER_CAPABILITIES=all"

# Ensure typical systemd execution space constraints are relaxed
LimitNOFILE=65536
TimeoutStartSec=0

ExecStartPre=-/usr/bin/docker stop vllm-server
ExecStartPre=-/usr/bin/docker rm vllm-server
ExecStart=/usr/bin/docker run --rm \
  --name vllm-server \
  --gpus all \
  --ipc=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -p 8000:8000 \
  -v /home/<user>/.cache/huggingface:/root/.cache/huggingface \
  nvcr.io/nvidia/vllm:26.04-py3 \
  vllm serve unsloth/Qwen3.6-27B-NVFP4 \
    --tokenizer Qwen/Qwen3.6-35B-A3B \
    --trust-remote-code \
    --tensor-parallel-size 1 \
    --max-model-len 65536 \
    --max-num-seqs 2 \
    --max-num-batched-tokens 4096 \
    --enforce-eager \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_xml \
    --gpu-memory-utilization 0.90 \
    --generation-config vllm \
    --override-generation-config '{"temperature":0.2,"top_p":0.95,"top_k":20,"min_p":0.05,"presence_penalty":0.0,"repetition_penalty":1.05,"preserve_thinking":false}' \
    --host 0.0.0.0 \
    --port 8000

ExecStop=/usr/bin/docker stop vllm-server

[Install]
WantedBy=multi-user.target
```

**Activation Commands:**
```bash
sudo systemctl daemon-reload
sudo systemctl restart vllm-qwen3.service
sudo journalctl -u vllm-qwen3.service -f # To follow logs in real time
```

### B. Service for Qwen3.6-27B Model (Complex Coding)
Use this configuration when deploying the model intended for complex coding tasks (e.g., unsloth/Qwen3.6-27B-NVFP4 tokenizer).

**File Location Example**: `/etc/systemd/system/vllm-qwen3.service`

```ini
[Unit]
Description=NVIDIA vLLM Qwen3.6-27B Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
Environment="VLLM_SLEEP_WHEN_IDLE=1"
Environment="HF_HOME=/root/.cache/huggingface"

# Override NVIDIA Container Runtime cgroup restrictions
Environment="NVIDIA_VISIBLE_DEVICES=all"
Environment="NVIDIA_DRIVER_CAPABILITIES=all"

# Ensure typical systemd execution space constraints are relaxed
LimitNOFILE=65536
TimeoutStartSec=0

ExecStartPre=-/usr/bin/docker stop vllm-server
ExecStartPre=-/usr/bin/docker rm vllm-server
ExecStart=/usr/bin/docker run --rm \
  --name vllm-server \
  --gpus all \
  --ipc=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -p 8000:8000 \
  -v /home/<user>/.cache/huggingface:/root/.cache/huggingface \
  nvcr.io/nvidia/vllm:26.04-py3 \
  vllm serve unsloth/Qwen3.6-27B-NVFP4 \
    --tokenizer Qwen/Qwen3.6-27B \
    --trust-remote-code \
    --tensor-parallel-size 1 \
    --max-model-len 65536 \
    --max-num-seqs 2 \
    --max-num-batched-tokens 4096 \
    --enforce-eager \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_xml \
    --gpu-memory-utilization 0.90 \
    --generation-config vllm \
    --override-generation-config '{"temperature":0.2,"top_p":0.95,"top_k":40,"min_p":0.05,"presence_penalty":0.0,"repetition_penalty":1.1,"preserve_thinking":false}' \
    --host 0.0.0.0 \
    --port 8000

ExecStop=/usr/bin/docker stop vllm-server

[Install]
WantedBy=multi-user.target
```

**Activation Commands:** (Similar to above, adjust service name if necessary)
```bash
sudo systemctl daemon-reload
sudo systemctl restart vllm-qwen3.service
sudo journalctl -u vllm-qwen3.service -f # To follow logs in real time
```

## 🖥️ IDE/VS Code Configuration Settings (for unifyChatProvider)
These settings define how your client application connects to the running endpoints, as seen in ~/.config/Code - Insiders/User/settings.json. Note that the configuration shows multiple models pointing to a shared base URL (http://<hostname>:8000/v1).

**Example Model Configurations:**
🔹 **Qwen3.6-35B-A3B (Fast Agentic)**
 - **ID**: `Qwen/Qwen3.6-35B-A3B`
 - **Capabilities**: Tool Calling Enabled (`"toolCalling": true`)
 - **Key Parameters**: Temperature: `0.2`, Top P: `0.95`, Top K: `20`, Presence Penalty: `0.0`.
 - **Extra Body Settings**: Min P (`min_p`): `0.05`, Repetition Penalty (`repetition_penalty`): `1.05`, Preserve Thinking (`preserve_thinking`): `false`.
🔹 **Qwen3.6-27B-NVFP4 (Complex Coding)**
 - **ID**: `unsloth/Qwen3.6-27B-NVFP4`
 - **Capabilities**: Tool Calling Enabled (`"toolCalling": true`)
 - **Key Parameters**: Temperature: `0.2`, Top P: `0.95`, Top K: `40`, Presence Penalty: `0.0`.
 - **Extra Body Settings**: Min P (min_p): `0.05`, Repetition Penalty (repetition_penalty): `1.1`, Preserve Thinking (`preserve_thinking`): `false`.

See reference: https://github.com/smallmain/vscode-unify-chat-provider/blob/2716832cd97fc56514cc7368d35704ffb8426a2d/src/config-ops.ts

```json
   "unifyChatProvider.endpoints": [
        {
            "type": "openai-chat-completion",
            "name": "unify-yourserver-GB10",
            "baseUrl": "http://100.66.8.46:8000/v1",
            "models": [
                {
                    "id": "Qwen/Qwen3.6-35B-A3B-NVFP4",
                    "name": "unify-yourserver-GB10-Qwen3.6-35B",
                    "maxInputTokens": 131072,
                    "maxOutputTokens": 8192,
                    "temperature": 0.2,
                    "topP": 0.95,
                    "topK": 20,
                    "presencePenalty": 0.0,
                    "extraBody": {
                        "min_p": 0.05,
                        "repetition_penalty": 1.05,
                        "preserve_thinking": false,
                        "max_thinking_tokens": 1024,
                        "stop": ["<|im_end|>"]
                    },
                    "capabilities": {
                        "toolCalling": true
                    }
                },
                {
                    "id": "unsloth/Qwen3.6-27B-NVFP4",
                    "name": "unify-yourserver-GB10-Qwen3.6-27B",
                    "maxInputTokens": 131072,
                    "maxOutputTokens": 8192,
                    "temperature": 0.2,
                    "topP": 0.95,
                    "topK": 40,
                    "presencePenalty": 0.0,
                    "extraBody": {
                        "min_p": 0.05,
                        "repetition_penalty": 1.1,
                        "preserve_thinking": false,
                        "stop": ["<|im_end|>"]
                    },
                    "capabilities": {
                        "toolCalling": true
                    }
                }
            ]
        }
    ]
```

## 🖥️ IDE/VS Code Configuration Settings (custom BYOK provider)
These settings define how your client application connects to the running endpoints, as seen in in ~/.config/Code - Insiders/User/chatLanguageModels.json. Note that the configuration shows multiple models pointing to a shared base URL (http://<hostname>:8000/v1).

See reference: https://github.com/microsoft/vscode/blob/4459d58b5428c36de656f9241ffd31e2a2118150/extensions/copilot/src/extension/byok/common/byokProvider.ts

```json
	{
		"name": "yourserver-GB10",
		"vendor": "customendpoint",
		"apiType": "chat-completions",
		"models": [
			{
				"id": "Qwen/Qwen3.6-35B-A3B-NVFP4",
				"name": "yourserver-GB10-Qwen3.6-35B",
				"url": "http://100.66.8.46:8000/v1",
				"toolCalling": true,
				"vision": false,
				"maxInputTokens": 131072,
				"maxOutputTokens": 4096,
				"requestHeaders": {
					"X-vLLM-Temperature": "0.1",
					"X-vLLM-Repetition-Penalty": "1.1",
					"X-vLLM-Preserve-Thinking": "false",
					"X-vLLM-Stop": "[\"<|im_end|>\"]"
    			}
			},
			{
				"id": "unsloth/Qwen3.6-27B-NVFP4",
				"name": "yourserver-GB10-Qwen3.6-27B",
				"url": "http://100.66.8.46:8000/v1",
				"toolCalling": true,
				"vision": false,
				"maxInputTokens": 131072,
				"maxOutputTokens": 8192,
				"requestHeaders": {
					"X-vLLM-Temperature": "0.2",
					"X-vLLM-Top-P": "0.95",
					"X-vLLM-Top-K": "40",
					"X-vLLM-Repetition-Penalty": "1.1",
					"X-vLLM-Presence-Penalty": "0.0",
					"X-vLLM-Preserve-Thinking": "false",
					"X-vLLM-Stop": "[\"<|im_end|>\"]"
				}
			},
			{
				"id": "nvidia/Gemma-4-31B-IT-NVFP4",
				"name": "yourserver-GB10-Gemma-4-31B",
				"url": "http://100.66.8.46:8000/v1",
				"toolCalling": true,
				"vision": false,
				"maxInputTokens": 65536,
				"maxOutputTokens": 16000
			}
		]
	}
```  

## 🚀 Alternative Startup Method (Shell Backgrounding)
If you prefer not using a full systemd service, the notes suggest using shell commands like `tmux` to run models in the background without setting up a persistent service.

```bash
# background:
tmux

# Leaving:
ctrl+b

# Attaching:
tmux attach
```
