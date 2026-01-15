# Prerequisites & Basic Tools

## 1. Useful Utilities

Before setting up the virtualization environment, it is helpful to install some basic utilities.

### Kate Markdown Viewer
To preview Markdown files effectively in Kate:
[Kate as Markdown Editor (German)](https://linuxundich.de/gnu-linux/kate-als-markdown-editor-mit-live-vorschau)

```bash
sudo apt install markdownpart
```

### Dolphin (File Manager) Authorization
To open files with root privileges directly from Dolphin:

```bash
sudo apt install kio-admin
```

### Brave Browser
Installing the Brave browser:

```bash
sudo apt install curl
sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
sudo curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
sudo apt update
sudo apt install brave-browser
```

## 2. Incus Installation

Incus is a modern system container and virtual machine manager.

Official Documentation: [Incus Installation](https://linuxcontainers.org/incus/docs/main/installing/)

```bash
sudo apt install incus
sudo apt install qemu-system
sudo incus admin init
```

### Initialization Questions & Recommended Answers

| Question | Answer | Note |
| :--- | :--- | :--- |
| **Use clustering?** | `no` | |
| **Configure new storage pool?** | `yes` | |
| **New storage pool name** | `default` | |
| **Storage backend** | `btrfs` | Recommended for snapshots/efficiency. |
| **Create new btrfs subvolume?** | `yes` | |
| **Create new local network bridge?** | `yes` | |
| **New bridge name** | `incusbr0` | |
| **IPv4 address** | `auto` | |
| **IPv6 address** | `auto` | |
| **Server available over network?** | `yes` | Needed for remote/local UI access. |
| **Bind address** | `all` | |
| **Bind port** | `8443` | |
| **Update stale cached images?** | `no` | |
| **Print YAML "init" preseed?** | `no` | |

## 3. Incus Web UI Setup

The Web UI allows you to manage your VMs and containers graphically.

References:
- [Simos Blog: Incus Web UI](https://blog.simos.info/how-to-install-and-setup-the-incus-web-ui/)
- [Zabbly Repository](https://github.com/zabbly/incus)

### Installation Steps

1.  **Add the Zabbly repository key:**
    ```bash
    sudo curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --show-keys --fingerprint
    sudo mkdir -p /etc/apt/keyrings/
    sudo curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
    ```

2.  **Add the repository source:**
    ```bash
    sudo sh -c 'cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
    Enabled: yes
    Types: deb
    URIs: https://pkgs.zabbly.com/incus/stable
    Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
    Components: main
    Architectures: $(dpkg --print-architecture)
    Signed-By: /etc/apt/keyrings/zabbly.asc
    EOF'
    ```

3.  **Install the UI package:**
    ```bash
    sudo apt-get update
    sudo apt install -y incus-ui-canonical
    ```

### Accessing the UI

1.  Open your browser and navigate to: `https://localhost:8443`
2.  **Certificate/Password:** You will need to authenticate.
3.  To allow the browser to connect securely, add your client certificate to Incus. (Usually, the browser will prompt you to generate one or you export it).
    
    If you have a certificate file (e.g., `incus-ui.crt`), add it:
    ```bash
    sudo incus config trust add-certificate Downloads/incus-ui.crt
    ```
