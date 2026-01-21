# AI Server Setup with Incus & Lemonade

This guide covers setting up a high-performance local AI server using **Lemonade** inside an Incus container. The critical factor for performance is successfully passing through the GPU and NPU to the container.

> **Note:** Currently, AMD provides limited NPU support for Linux on the Strix Halo platform. The Lemonade server with `llama.cpp` primarily utilizes the GPU (via Vulkan or ROCm). However, we configure the NPU passthrough anticipating future updates.

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

### ROCm Drivers
Install the AMD ROCm drivers (essential for GPU acceleration).
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
apt install unzip
wget https://github.com/lemonade-sdk/lemonade/releases/latest/download/lemonade-server-minimal_9.1.3_amd64.deb
sudo dpkg -i lemonade-server-minimal_9.1.3_amd64.deb
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

Lemonade can run in **Service Mode** (awaits client requests to load models) or **Run Mode** (pre-loads a specific model).

Ensure you expose the server to the network with `--host 0.0.0.0`.

### Examples

**1. Nemotron (Vulkan Backend)**
ROCm may be unstable with certain models like Nemotron. Use Vulkan in these cases. Note that "Reasoning" features are currently disabled (`--reasoning-budget 0`) for stability.

```bash
lemonade-server pull Nemotron-3-Nano-30B-A3B-GGUF
lemonade-server run Nemotron-3-Nano-30B-A3B-GGUF --host 0.0.0.0 --port 8080 --log-level debug --llamacpp vulkan --llamacpp-args "-c 16384 --reasoning-budget 0"
```

**2. Qwen (ROCm Backend)**
Qwen 3 works well with ROCm and supports reasoning features.

```bash
lemonade-server pull Qwen3-30B-A3B-Instruct-2507-GGUF
lemonade-server run Qwen3-30B-A3B-Instruct-2507-GGUF --host 0.0.0.0 --port 8080 --log-level debug --llamacpp rocm --llamacpp-args "-c 16384 --reasoning-budget -1"
```

**3. Directly usage of llama.cpp** 
To load a model directly with llama.cpp find the snapshot location where the model is downloaded from huggingface: 
```bash
find ~/.cache/huggingface/hub -name "*.gguf"
```
Then decide if you want to use the vulkan or ROCm backend, which are installed in different locations of lemonade.   
With Vulkan (replace the snapshot id with yours!):
```bash
/usr/local/share/lemonade-server/llama/vulkan/build/bin/llama-server -m /root/.cache/huggingface/hub/models--unsloth--Nemotron-3-Nano-30B-A3B-GGUF/snapshots/9ad8b366c308f931b2a96b9306f0b41aef9cd405/Nemotron-3-Nano-30B-A3B-UD-Q4_K_XL.gguf --ctx-size 32768 --temp 0.6 --top-p 0.9 --host 0.0.0.0
```
With ROCm (replace the snapshot id with yours!):
```bash
/usr/local/share/lemonade-server/llama/rocm/llama-server -m /root/.cache/huggingface/hub/models--unsloth--Nemotron-3-Nano-30B-A3B-GGUF/snapshots/9ad8b366c308f931b2a96b9306f0b41aef9cd405/Nemotron-3-Nano-30B-A3B-UD-Q4_K_XL.gguf --ctx-size 32768 --temp 0.6 --top-p 0.9 --host 0.0.0.0
```
The Server may not start if the ROCm libraries are not found. Either you switch to the '/usr/local/share/lemonade-server/llama/rocm/' directory and run the llama-server command there.   
Or you temprary set environment variables of the library path to:
```bash
export LD_LIBRARY_PATH=/opt/rocm/lib:/usr/local/share/lemonade-server/llama/rocm:
```

**4. glm-4.7-flash from hugging face**
```bash
lemonade-server pull user.GLM-4.7-Flash-GGUF --checkpoint unsloth/GLM-4.7-Flash-GGUF:UD-Q4_K_XL --recipe llamacpp
lemonade-server run user.GLM-4.7-Flash-GGUF --host 0.0.0.0 --port 8080 --log-level debug --llamacpp rocm --llamacpp-args "-c 32768 --temp 0.7 --min-p 0.01 --top-p 1.00 --dry-multiplier 1.1 --fit on"
```
For function calling --jinja has to be used. Unfortunately this is currently not supported by the lemonade-server. This will not work:
```bash
lemonade-server run user.GLM-4.7-Flash-GGUF --host 0.0.0.0 --port 8080 --log-level debug --llamacpp rocm --llamacpp-args "-c 32768 --chat-template-file /root/glm4_template.jinja  --jinja --temp 0.7 --min-p 0.01 --top-p 1.00 --reasoning-budget -1 --dry-multiplier 1.1 --fit on"
```
You only can run it directly with llama-server at the moment:
```bash
/usr/local/share/lemonade-server/llama/vulkan/build/bin/llama-server -m /root/.cache/huggingface/hub/models--unsloth--GLM-4.7-Flash-GGUF/snapshots/218bcb725e428c5b8c4153bcf5bf7ead738a9799/GLM-4.7-Flash-UD-Q4_K_XL.gguf --jinja --threads -1 --ctx-size 32768 --temp 0.7 --min-p 0.01 --top-p 1.00 --dry-multiplier 1.1 --fit on --host 0.0.0.0
/usr/local/share/lemonade-server/llama/rocm/llama-server -m /root/.cache/huggingface/hub/models--unsloth--GLM-4.7-Flash-GGUF/snapshots/218bcb725e428c5b8c4153bcf5bf7ead738a9799/GLM-4.7-Flash-UD-Q4_K_XL.gguf --jinja --threads -1 --ctx-size 32768 --temp 0.7 --min-p 0.01 --top-p 1.00 --dry-multiplier 1.1 --fit on --host 0.0.0.0
```

### Client Integration

**Check Status:**
`http://<container-ip>:8080/api/v1`

**Tools:**
- **VS Code:** Use the **Continue** extension.
- **Open Web UI:** Connects easily to OpenAI-compatible endpoints.
- **iPlus Framework:**
  - **Endpoint:** `http://<IP>:8080/api/v1/chat/completions`
  - **Prerequisite:** The OpenAI client within the ChatBot requires **Node.js**. Download the `.msi` installer from [nodejs.org](https://nodejs.org/en/download) and install it within your WINE environment if running legacy Windows components.
