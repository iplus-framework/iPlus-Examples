# AI Server Setup with Incus & Lemonade

This guide covers running **Lemonade** in an Incus container, with GPU-backed models served through llama.cpp and supported AMD XDNA 2 models served on the NPU through FastFlowLM. The examples below reflect the current container setup; check the linked release pages for newer compatible packages and supported models.

## 1. Container Configuration

### NPU Passthrough
First, check if the NPU is recognized on the host system:
```bash
ls -l /dev/accel/accel*
```

Create a new container or update an existing one to add the NPU device. Replace `gipDLVmAIServ` with your container name:
```bash
sudo incus config device add gipDLVmAIServ xdna-npu unix-char path=/dev/accel/accel0
```

Grant necessary permissions (ensure the GID matches the `render` group, typically 992 or similar):
```bash
getent group render
sudo incus config device set gipDLVmAIServ xdna-npu gid=992 mode=0660
sudo incus config device add gipDLVmAIServ dev_kfd unix-char source=/dev/kfd path=/dev/kfd gid=992 mode=0660
```

### GPU Passthrough
Add the GPU device. On Ubuntu 24.04 and newer Incus versions, the container often requires privileged status and specific syscall intercepts to access hardware accelerators correctly.

```bash
sudo incus config device add gipDLVmAIServ mygpu gpu
sudo incus config set gipDLVmAIServ security.privileged true
sudo incus config set gipDLVmAIServ security.syscalls.intercept.mknod true
sudo incus config set gipDLVmAIServ security.syscalls.intercept.setxattr true
sudo incus config set gipDLVmAIServ limits.kernel.memlock unlimited
```

### Resource Limits (CPU/RAM)
Configure resources via the Incus UI or CLI.
- **CPU:** Primarily used for model loading. During inference, the GPU handles the workload. Testing suggests that assigning ~6 cores is sufficient; allocating all cores does not significantly improve performance as Lemonade may not utilize them all.
- **Memory:** Allocate sufficient RAM (e.g., 54 GiB) depending on the models you plan to run.

**Example Profile Configuration (YAML):**

```yaml
architecture: x86_64
config:
  image.os: Ubuntu
  image.release: noble
  limits.cpu: '6'
  limits.kernel.memlock: unlimited
  limits.memory: 54GiB
  security.privileged: 'true'
  security.syscalls.intercept.mknod: 'true'
  security.syscalls.intercept.setxattr: 'true'
devices:
  dev_kfd:
    gid: '992'
    mode: '0660'
    path: /dev/kfd
    source: /dev/kfd
    type: unix-char
  mygpu:
    type: gpu
  xdna-npu:
    gid: '992'
    mode: '0660'
    path: /dev/accel/accel0
    type: unix-char
  root:
    path: /
    pool: default
    size: 120GiB
    type: disk
```

## 2. Server Installation

Start the container and open a shell session inside it.

### FastFlowLM NPU Runtime
FastFlowLM can now use the AMD XDNA 2 NPU directly on Linux. This is separate from the ROCm/Vulkan path used by Lemonade with `llama.cpp`.

**References:**
- [Lemonade: LLMs on Linux with FastFlowLM](https://lemonade-server.ai/flm_npu_linux.html)
- [FastFlowLM Linux install docs](https://fastflowlm.com/docs/install_lin/)
- [FastFlowLM releases](https://github.com/ROCm/FastFlowLM/releases)

#### Host prerequisites
Install the AMD XRT and XDNA kernel driver packages on the **host** so the NPU device is available and passed through to the container:

```bash
sudo add-apt-repository ppa:amd-team/xrt
sudo apt update
sudo apt install libxrt-npu2 amdxdna-dkms
sudo reboot
```

#### Container prerequisites
Install the NPU runtime package inside the **Incus container** as well:

```bash
sudo add-apt-repository ppa:amd-team/xrt
sudo apt update
sudo apt install libxrt-npu2
sudo reboot
```

#### Install FastFlowLM
Download the Ubuntu package that matches the container release and architecture from the FastFlowLM releases page. This container uses FastFlowLM 1.0.2 on Ubuntu 24.04 amd64:

```bash
wget https://github.com/ROCm/FastFlowLM/releases/download/v1.0.2/fastflowlm_1.0.2_ubuntu24.04_amd64.deb
sudo apt install ./fastflowlm_1.0.2_ubuntu24.04_amd64.deb
flm version
```

If installing a later release, use its matching asset from the releases page rather than reusing the example version above.

#### Required memlock configuration
FastFlowLM validation will fail if the container cannot lock enough memory for NPU execution.

Check the current limit:

```bash
ulimit -l
```

If it is not `unlimited`, configure all of the following inside the container:

1. Ensure the Incus container has the kernel memlock limit enabled:

```bash
sudo incus config set gipDLVmAIServ limits.kernel.memlock unlimited
```

2. Edit `/etc/security/limits.conf` and add:

```text
* soft memlock unlimited
* hard memlock unlimited
```

3. Edit `/etc/systemd/system.conf` and `/etc/systemd/user.conf`, then set:

```text
DefaultLimitMEMLOCK=infinity
```

4. Reboot the container after changing the limits.

#### Validate NPU access
After reboot, verify that the NPU, firmware, driver, and memlock settings are all detected:

```bash
flm validate
```

Example output:

```text
[Linux]  Kernel: 6.17.0-108014-tuxedo
[Linux]  NPU: /dev/accel/accel0 with 8 columns
[Linux]  NPU FW Version: 1.1.2.64
[Linux]  amdxdna version: 0.6
[Linux]  Memlock Limit: infinity
```

If `flm validate` does not report the NPU or shows a finite memlock limit, re-check the host driver installation, the Incus device passthrough, and the systemd/limits configuration above before troubleshooting FastFlowLM itself.

To confirm models installed by FastFlowLM are available:

```bash
flm list
```

The Lemonade service must use the same FLM model directory. In this container, the `lemond.service` override sets `FLM_MODEL_PATH=/root/.config/flm`, so FLM models are stored under `/root/.config/flm/models`. After pulling a model with `flm`, restart Lemonade to refresh its model list, then refresh the web app:

```bash
sudo systemctl restart lemond.service
```

See [Using FastFlowLM models in Lemonade](#using-fastflowlm-models-in-lemonade) for the CLI checks.

### ROCm Drivers
The commands below pin ROCm 7.1.1 for Ubuntu 24.04 (`noble`); they are an example, not a claim that this is the latest release. Check AMD's current guide before changing the ROCm version or Ubuntu release. With Incus GPU passthrough, install the kernel driver on the host and the required user-space packages in the container.
*Reference: [ROCm Installation on Linux](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/install-methods/package-manager/package-manager-ubuntu.html)*

```bash
apt-get update && apt-get install wget
mkdir --parents --mode=0755 /etc/apt/keyrings
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

sudo tee /etc/apt/sources.list.d/rocm.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.1.1 noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/7.1.1/ubuntu noble main
EOF

sudo tee /etc/apt/preferences.d/rocm-pin-600 << EOF
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

sudo apt update
apt install rocm rocm-hip-runtime rocm-hip-libraries
```

**Environment Variables**
Configure the library path and force the graphics version (required for Radeon 890M / gfx1150 support). Add these lines to your `~/.bashrc` to make them persistent:

```bash
export LD_LIBRARY_PATH=/opt/rocm/lib:$LD_LIBRARY_PATH
export HSA_OVERRIDE_GFX_VERSION=11.5.0
```

Apply changes:
```bash
source ~/.bashrc
```

### Install Lemonade
Download and install the minimal Lemonade server.
*Reference: [Lemonade Server Docs](https://lemonade-server.ai/docs/server/)*

```bash
sudo add-apt-repository ppa:lemonade-team/stable
sudo apt install lemonade-server
sudo update-pciids
```

## 3. BIOS & System Tuning (Optional / Troubleshooting)

### VRAM Configuration
On AMD Ryzen AI 9 laptops, you can manually set the VRAM size in the BIOS (up to 16GB). Usually, "Auto" is sufficient. I did not observe performance gains by maximizing it manually.

### Troubleshooting: LVM Activation Error
Changing the VRAM size in BIOS might cause the container to fail on boot with LVM errors (e.g., `exit status 5`, `Activation of logical volume... is prohibited`). This occurs because the system attempts to activate LVM before the kernel finishes reallocating memory addresses for the VRAM.

**Fix 1: LVM Configuration**
Edit `/etc/lvm/lvm.conf` on the host:
```bash
# Locate thin_check_options and uncomment the line to skip mappings
thin_check_options = [ "-q", "--skip-mappings" ]
```

**Fix 2: GRUB Delay**
Edit `/etc/default/grub` (or `/boot/grub/grub.cfg`) to add a boot delay:
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash rootdelay=5"
```
Then update initramfs and reboot:
```bash
sudo update-initramfs -u
reboot
```

After reboot, verify VRAM size:
```bash
rocm-smi --showmeminfo vram
```

## 4. Usage
  
Configuration and model locations when lemonade is started from shell/CLI:
```bash
~/.cache/lemonade/recipe_options.json
~/.cache/lemonade/user_models.json
~/.cache/lemonade/config.json
~/.cache/huggingface/hub
~/.config/flm/models
```
   
Configuration and model locations when lemonade is started with systemd:
```bash
/var/lib/lemonade/.cache/lemonade/recipe_options.json
/var/lib/lemonade/.cache/lemonade/user_models.json
/var/lib/lemonade/.cache/lemonade/config.json
/var/lib/lemonade/.cache/huggingface/hub
/root/.config/flm/models
```

Lemonade's model cache and FLM's model directory are separate. Lemonade models downloaded by the systemd service use `/var/lib/lemonade/.cache`; FLM models use the path in `FLM_MODEL_PATH`. This installation runs `lemond.service` as root and sets `FLM_MODEL_PATH=/root/.config/flm`. If you change the service user or FLM path, update the environment variable and permissions so both `flm` and Lemonade use the same directory.

The systemd service reads its server settings from `/var/lib/lemonade/.cache/lemonade/config.json`. Set `host` to `0.0.0.0` and `port` to `8080` there to expose the server on the container network. The shell-launched service may use a different config file under the launching user's cache directory.

To ensure that the GPU is utilized when Lemonade is launched via systemd, you must provide the necessary environment variables to the service:

```bash
sudo systemctl edit lemond.service
```
Copy this text and save:
```
[Service]
User=root
Environment="FLM_MODEL_PATH=/root/.config/flm"
Environment="HSA_OVERRIDE_GFX_VERSION=11.5.0"
Environment="HIP_VISIBLE_DEVICES=0"
LimitMEMLOCK=infinity
```
Restart:
```bash
sudo systemctl daemon-reload
sudo systemctl restart lemond.service
```


This service runs in **Service Mode** and loads models when requested. The `lemonade` CLI is the client for managing and loading models; `lemond` runs the server.


Starting or checking the server
```bash
# As service
sudo systemctl start lemond.service
sudo systemctl status lemond.service
# Run in the foreground instead of using systemd
lemond
```

### Using FastFlowLM models in Lemonade

For this container, the Lemonade API is on port 8080 and requires the API key configured for the service. Set the CLI connection options in the shell (use the same key configured on the service):

```bash
export LEMONADE_HOST=127.0.0.1
export LEMONADE_PORT=8080
export LEMONADE_API_KEY="<service-api-key>"
```

List FLM-installed models and Lemonade's downloaded models:

```bash
flm list
lemonade list --downloaded
```

If a newly installed FLM model appears in `flm list` but not in Lemonade, restart `lemond.service` and refresh the browser app. For example, the Qwen 3.6 model installed in this container is listed as `builtin.qwen3.6-moe-35b-a3b-FLM`. Select it in the app or load it from the CLI:

```bash
lemonade load builtin.qwen3.6-moe-35b-a3b-FLM
```

### Optional: Run an explicit llama.cpp model

**1. Nemotron (Vulkan Backend)**
ROCm may be unstable with certain models like Nemotron. Use Vulkan in these cases. Note that "Reasoning" features are currently disabled (`--reasoning-budget 0`) for stability.

```bash
lemonade pull Nemotron-3-Nano-30B-A3B-GGUF
lemonade run Nemotron-3-Nano-30B-A3B-GGUF --llamacpp vulkan --llamacpp-args "-c 16384 --reasoning-budget 0"
```

**2. Qwen (ROCm Backend)**
Qwen 3 works well with ROCm and supports reasoning features.

```bash
lemonade pull Qwen3-30B-A3B-Instruct-2507-GGUF
lemonade run Qwen3-30B-A3B-Instruct-2507-GGUF --llamacpp rocm --llamacpp-args "-c 16384 --reasoning-budget -1"
```

**3. Run llama.cpp directly**
Prefer the Lemonade CLI above so Lemonade can manage model loading. For direct llama.cpp use, find the model snapshot and the version-specific `llama-server` binary installed by Lemonade:
```bash
find /var/lib/lemonade/.cache/huggingface/hub -name "*.gguf"
find /var/cache/lemonade/bin -type f -name llama-server
```

### Client Integration

**Check Status and open lemonade app:**
`http://<container-ip>:8080`

**Tools:**
- **VS Code:**
  - Use the [VS Code Insiders Version](https://code.visualstudio.com/insiders/) and Copilot with a [custom endpoint Model](https://code.visualstudio.com/docs/copilot/customization/language-models#_add-a-custom-endpoint-model). Unfortunately the native Copilot provider sends a richer request with additional fields that lemonades llama.cpp's server doesn't recognize for `"apiType": "chat-completions"`. Maybe the future vllm backed will support it. Example setting chatLanguageModels.json:
    ```json
    	{
		"name": "lemonade-local",
		"vendor": "customendpoint",
		"apiType": "chat-completions",
		"models": [
			{
        "id": "builtin.qwen3.6-moe-35b-a3b-FLM",
				"name": "lemonade-local-Qwen3.6",
				"url": "http://myhost:8080/api/v1/chat/completions",
				"toolCalling": true,
        "vision": true,
        "maxInputTokens": 32768,
				"maxOutputTokens": 16000,
				"settings": {
					"temperature": 0.6,
					"top_p": 0.95,
					"top_k": 20,
					"frequency_penalty": 1.0,
					"presence_penalty": 0.0
				}
			}
		]
	},
    ```
  - The Standard VS Code Version doesn't support custom models with Copilot but there are two alternatives:
  - Use the [unify chat provider](https://marketplace.visualstudio.com/items?itemName=SmallMain.vscode-unify-chat-provider) extension.
  Example setting settings.json:
    ```json
    "unifyChatProvider.endpoints": [
        {
            "models": [
                {
                    "id": "builtin.qwen3.6-moe-35b-a3b-FLM",
                    "capabilities": {
                        "toolCalling": true
                    },
                    "name": "lemonade-local-Qwen3.6",
                    "maxInputTokens": 32768,
                    "settings": {
                        "temperature": 0.6,
                        "top_p": 0.95,
                        "top_k": 20,
                        "frequency_penalty": 1.0,
                        "presence_penalty": 0.0
                    }                   
                }
            ],
            "type": "openai-chat-completion",
            "baseUrl": "http://myhost:8080/v1",
            "name": "lemonade-local"
        }
    ],
    ```
  - Or the [lemonade extension](https://marketplace.visualstudio.com/items?itemName=lemonade-sdk.lemonade-sdk) for copilot.
- **iPlus Framework:**
  - **Endpoint:** `http://myhost:8080/api/v1/chat/completions`



### Accessing the Server

Once configured, access your AI server via HTTPS using the following URL:
```
https://gipDLVmAIServ.incus:8081
https://<yourhostname>:8081
```
OpenAI compatible API:
```
https://gipDLVmAIServ.incus:8081/api/v1
https://<yourhostname>:8081/api/v1
```
