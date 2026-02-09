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


## 5. Network Manager

**Network Manager** is a powerful tool for managing network connections, including VPNs, through a unified interface. It supports various VPN protocols, including OpenVPN, FortiClient SSL, GlobalProtect, and L2TP/IPSec, allowing you to manage all your VPN connections in one place.

### Install L2TP/IPSec Support

To enable L2TP/IPSec VPN connections in Network Manager, you need to install the required packages:

```bash
sudo add-apt-repository ppa:nm-l2tp/network-manager-l2tp
sudo apt-get update
sudo apt-get install network-manager-l2tp network-manager-l2tp-gnome
```

After installation, restart the Network Manager service to apply the changes:

```bash
sudo systemctl restart NetworkManager
```

### Add a New L2TP/IPSec Connection

To set up an L2TP/IPSec VPN connection in Network Manager:

1. Open the **Network Settings** UI:
   - On Ubuntu, go to **Settings > Network > VPN > Add VPN**.

2. Select **Layer 2 Tunneling Protocol (L2TP)** from the list of VPN types.

3. Fill in the following details:
   - **Gateway**: Enter the VPN server address (e.g., `vpn.example.com`).
   - **Username**: Enter your VPN username.
   - **Password**: Enter your VPN password.

4. Click **IPSec Settings** and configure the following:
   - **Enable IPsec tunnel to L2TP host**: Check this box.
   - **Pre-shared key**: Enter the pre-shared key provided by your VPN administrator.
   - **Enforce UDP encapsulation**: This is a standard behaviour in Windows 
   - **Phase1 Algorithms**: OPTIONAL Use `3des-sha1-modp1024` (or as specified by your VPN server).
   - **Phase2 Algorithms**: OPTIONAL Use `3des-sha1` (or as specified by your VPN server).

5. Under the **PPP Settings** section:
   - **Authentication**: Ensure only **MSCHAPv2** is checked (in most common cases).
   - **Use Point-to-Point encryption (MPPE)**: Check this box.
   - **Allow BSD data compression**, **Allow Deflate data compression**, and **Use TCP header compression**: UNCHECK all these boxes.
   - **Send PPP echo packets**: Check this box.
   - **MTU**: If you are in an Incus VM, then reduce the MTU Size to 1400. Run the VM in a bridged Network and not in the default incusbr0 NAT. Read 03-network-setup.

6. Save the configuration and connect to the VPN.

### Notes for Windows-Like Behavior

To ensure the L2TP/IPSec connection behaves like it was set up on a Windows machine:
- Use the same **pre-shared key**, **username**, and **password** as configured on the Windows client.
- Match the **Phase1/Phase2 algorithms** and **PPP settings** to the Windows configuration.
- If the VPN server requires specific DNS settings, ensure they are configured in the **IPv4 Settings** tab.

### Managing Other VPN Protocols

Network Manager also supports managing the following VPN protocols:
- **FortiClient SSL**: Install the FortiClient software and configure it through Network Manager.
- **GlobalProtect**: Use the `openconnect` plugin or the official GlobalProtect client.
- **OpenVPN**: Install the `network-manager-openvpn` package and import `.ovpn` configuration files directly into Network Manager.

With Network Manager, you can manage all these VPN connections through a single UI, making it easier to switch between different VPNs as needed.

---

## Ubuntu VM/Container Login Tips

If you download official cloud images, they often have no default password for `root` or `ubuntu`.

**Reset Password from Host:**
```bash
sudo incus exec CONTAINER_NAME -- passwd ubuntu
```
Then you can log in via console or SSH.

### Configuring Netplan for Network Manager

If you want to use **Network Manager** to manage your network interfaces, you need to configure Netplan accordingly. This is especially useful when managing VPN connections through Network Manager.

#### Steps to Configure Netplan

1. Open the Netplan configuration file for editing. For example, if your configuration file is `/etc/netplan/10-lxc.yaml`, run:
   ```bash
   sudo nano /etc/netplan/10-lxc.yaml
   ```

2. Modify the file to use `renderer: NetworkManager` for the desired interface. Below is an example configuration:

   ```yaml
   network:
     version: 2
     renderer: NetworkManager
     ethernets:
       enp5s0:
         dhcp4: true
         dhcp-identifier: mac
   ```

   - **`renderer: NetworkManager`**: Specifies that Network Manager should manage the `enp5s0` interface.
   - **`dhcp4: true`**: Enables DHCP for IPv4 to automatically obtain an IP address.
   - **`dhcp-identifier: mac`**: Ensures the DHCP client uses the MAC address as the identifier.

3. Apply the changes:
   ```bash
   sudo netplan apply
   ```

4. Verify that Network Manager is managing the interface:
   ```bash
   nmcli device status
   ```

   Ensure the `enp5s0` interface (default interface name of an Ubuntu LXC container) is listed as `managed` by Network Manager.
   You can activate it with this command:
   ```bash
   sudo nmcli device set enp5s0 managed yes
   ```
By configuring Netplan to use Network Manager, you can seamlessly manage your network interfaces and VPN connections through a single interface.
