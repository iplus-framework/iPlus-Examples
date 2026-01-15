# VPN & Security Isolation

A major pain point for developers is managing multiple, often conflicting VPN clients required for customer support (FortiClient, Cisco AnyConnect, SonicWall, OpenVPN, etc.). Installing these on your main OS can disrupt your local network and introduce security risks.

**The Solution:** Run each VPN client in its own lightweight Linux Container.

## General Strategy
1.  Launch a minimal Ubuntu/Debian container.
2.  Install the specific VPN client.
3.  Use `ssh` with SOCKS proxy (`ssh -D`) or `sshuttle` to tunnel traffic from your host through the container to the customer network.

---

## 1. OpenVPN

**Install:**
```bash
sudo apt-get install network-manager-openvpn-gnome openconnect network-manager-openconnect network-manager-openconnect-gnome
```

**Connect (CLI):**
```bash
sudo openvpn --config /SHARED/config/Client/vpn-config.ovpn
```

## 2. FortiClient

Official setup for Ubuntu 22.04+:

```bash
sudo wget -O - https://repo.fortinet.com/repo/forticlient/7.4/ubuntu22/DEB-GPG-KEY | gpg --dearmor | sudo tee /usr/share/keyrings/repo.fortinet.com.gpg

sudo nano /etc/apt/sources.list.d/repo.fortinet.com.list
# Add: deb [arch=amd64 signed-by=/usr/share/keyrings/repo.fortinet.com.gpg] https://repo.fortinet.com/repo/forticlient/7.4/ubuntu22/ stable non-free

sudo apt-get update
sudo apt install forticlient
```

## 3. SonicWall NetExtender

Requires Java and PPP.

```bash
sudo apt install default-jre pptpd -y
# Download NetExtender Linux TGZ
cd ./NetExtender.Linux-10.2.845.x86_64/netExtenderClient
sudo ./install
```

## 4. Palo Alto GlobalProtect

Use `openconnect` (which supports PAN GlobalProtect) preferably, or the official Linux app.

References:
*   [Palo Alto Docs](https://docs.paloaltonetworks.com/globalprotect/5-1/globalprotect-app-user-guide/globalprotect-app-for-linux/download-and-install-the-globalprotect-app-for-linux)
*   [OpenConnect Guide](https://system-administrator.pages.cs.sun.ac.za/globalprotect-openconnect/#setup-and-use)

---

## Ubuntu VM/Container Login Tips

If you download official cloud images, they often have no default password for `root` or `ubuntu`.

**Reset Password from Host:**
```bash
sudo incus exec CONTAINER_NAME -- passwd ubuntu
```
Then you can log in via console or SSH.
