# AI Server Setup with Incus & Lemonade

This guide covers setting up a high-performance local AI server using **Lemonade** inside an Incus container. The critical factor for performance is successfully passing through the GPU and NPU to the container.

> **Update (March 2026):** Linux NPU support is now available for **AMD XDNA 2** devices through **FastFlowLM**. On current Ryzen AI Linux systems, the practical setup is to keep **Lemonade + llama.cpp** for GPU-backed serving and add **FastFlowLM** when you want to run supported models directly on the NPU. See the FastFlowLM Linux guides for the current support matrix and package sources.

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
- [FastFlowLM releases](https://github.com/FastFlowLM/FastFlowLM/releases)

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
Download the current Ubuntu package from the FastFlowLM releases page. For example:

```bash
wget https://github.com/FastFlowLM/FastFlowLM/releases/download/v0.9.35/fastflowlm_0.9.35_ubuntu24.04_amd64.deb
sudo apt install ./fastflowlm*.deb
```

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
sudo add-apt-repository ppa:lemonade-team/stable
sudo apt install lemonade-server
sudo update-pciids
```

Arrows fixed, async Dialog, TimeSeries with OxyPlot, FillLevel still bugy

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
   
Configuration and model locations:
```bash
~/.cache/lemonade/recipe_options.json
~/.cache/lemonade/user_models.json
/etc/lemonade/lemonade.conf
/root/.cache/huggingface/hub/
/var/lib/lemonade/.cache/huggingface/hub/
```

Ensure you expose the server to the network with `--host 0.0.0.0`.   

Starting Server
```bash
# As service
systemctl start lemonade-server.service
# Or from shell
lemonade-server serve --host 0.0.0.0 --port 8080 --global-timeout 2400
```

### Optional: Examples manual run of an explicit model

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


## 5. HTTPS Setup with Nginx (for GitHub Copilot Compatibility)

Since GitHub Copilot only supports HTTPS connections to OpenAI-compatible endpoints, an HTTPS proxy is required to expose the Lemonade AI server securely. This section guides you through installing and configuring **Nginx** to proxy traffic from HTTPS (`https://<domain>:8081`) to the internal Lemonade server running on port `8080`.

### Prerequisites
Ensure the following are installed and configured:
- `apt` package manager
- `mkcert` for generating self-signed TLS certificates
- A local domain name (e.g., <yourhostname> `gipDLVmAIServ.incus`) pointing to your host system

### Step-by-Step Setup

1. **Update package list and install Nginx**
   ```bash
   sudo apt update
   sudo apt install nginx -y
   ```

2. **Generate self-signed TLS certificate using mkcert**
   ```bash
   mkcert -install
   mkcert localhost 127.0.0.1 ::1
   ```

3. **Move generated certificate and key to Nginx SSL directory**
   ```bash
   sudo mv localhost+2.pem /etc/ssl/certs/
   sudo mv localhost+2-key.pem /etc/ssl/private/
   ```

4. **Create Nginx configuration file for Lemonade server**
   Create the configuration file at `/etc/nginx/sites-available/lemonade`:
   ```nginx
   server {
       listen 8081 ssl;
       server_name gipDLVmAIServ.incus;
       
       ssl_certificate /etc/ssl/certs/localhost+2.pem;
       ssl_certificate_key /etc/ssl/private/localhost+2-key.pem;
       
       location / {
           # Forward requests to the internal Lemonade server (port 8080)
           proxy_pass http://127.0.0.1:8080;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
           
           # Disable buffering to ensure real-time streaming of LLM responses
           proxy_buffering off;
           proxy_cache off;
           proxy_read_timeout 300s;
       }
   }
   ```

5. **Configure Nginx to use the new site**
   - Remove the default site:
     ```bash
     sudo rm /etc/nginx/sites-available/default
     ```
   - Create a symbolic link to enable the new configuration:
     ```bash
     sudo ln -s /etc/nginx/sites-available/lemonade /etc/nginx/sites-enabled/
     ```

6. **Test Nginx configuration for syntax errors**
   ```bash
   sudo nginx -t
   ```

7. **Restart Nginx to apply changes**
   ```bash
   sudo systemctl restart nginx
   ```

8. **Disable Nginx from starting on boot (optional)**
   ```bash
   sudo systemctl disable nginx
   ```

9. **Stop Lemonade server service (to avoid conflicts)**
   ```bash
   sudo systemctl disable lemonade-server.service
   sudo systemctl stop lemonade-server.service
   ```

### Start Script: `start-lemonade-nginx.sh`

To ensure the Lemonade server starts before Nginx, create a startup script:

```bash
nano /home/user/start-lemonade-nginx.sh
```

Add the following content:
```bash
#!/bin/bash
# 1. Start Lemonade Server in the background
echo "Starting Lemonade Server on port 8080..."
lemonade-server serve --host 0.0.0.0 --port 8080 --global-timeout 2400 &
# 2. Wait a few seconds for Lemonade to initialize
sleep 5
# 3. Start Nginx in foreground mode (to keep process alive)
echo "Starting Nginx HTTPS Proxy on port 8081..."
sudo nginx -g "daemon off;"
```

Make the script executable and run it:
```bash
chmod +x start-lemonade-nginx.sh
./start-lemonade-nginx.sh
```

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
