# Network Configuration

You can configure Incus instances in two primary network modes:
1.  **NAT (Default):** VMs are in a private subnet. Incus acts as a gateway/router. Safe and isolated.
2.  **Bridged (LAN):** VMs appear as devices on your physical LAN. Necessary if you need direct external access to VMs without port forwarding.

## 1. Standard NAT Network (incusbr0)

By default, an `incusbr0` bridge is created.

**Typical Config:**
```yaml
config:
  dns.mode: managed
  ipv4.address: 10.40.168.1/24
  ipv4.nat: 'true'
```

### Addressing DNS Resolution Issues
To access VMs by name (e.g., `ping gipDLVmWin11.incus`) from the host:

1.  **Configure Host DNS:**
    ```bash
    sudo resolvectl dns incusbr0 10.40.168.1
    sudo resolvectl domain incusbr0 '~incus'
    sudo resolvectl dnssec incusbr0 off
    sudo resolvectl dnsovertls incusbr0 off
    ```

2.  **Make it Persistent:**
    Edit `/etc/systemd/resolved.conf`:
    ```ini
    [Resolve]
    DNS=10.40.168.1
    Domains=~incus
    DNSSEC=no
    DNSOverTLS=no
    ```
    Restart service:
    ```bash
    sudo systemctl restart systemd-resolved
    ```

## 2. Bridged Network (Host LAN)

If you need the VM to have an IP from your physical router (e.g., 192.168.x.x), you must create a bridge on the host OS managed by NetworkManager, and tell Incus to use it.

### Setting up the Host Bridge (`br0`)

1.  **Identify your interface:** `ip link` or `nmcli connection show` (e.g., `eth0`).
2.  **Create Bridge:**
    ```bash
    sudo nmcli connection add type bridge ifname br0 con-name br0
    ```
3.  **Add Slave Interface:**
    ```bash
    sudo nmcli connection add type bridge-slave ifname eth0 master br0 con-name br0-slave-eth0
    ```
4.  **Disable STP (Spanning Tree) to speed up connections:**
    ```bash
    sudo nmcli connection mod br0 bridge.stp no
    ```
5.  **Activate Bridge:**
    ```bash
    # Shutdown existing connection
    sudo nmcli connection down "Wired connection 1"
    # Bring up bridge
    sudo nmcli connection up br0
    sudo nmcli connection up br0-slave-eth0
    ```

### Configuring Incus profile
Create a profile `LANofHost` in Incus to use this bridge.

```yaml
name: LANofHost
devices:
  eth0:
    parent: br0
    nictype: bridged
    type: nic
```

Apply this profile to your VM:
```bash
sudo incus profile assign gipDLVmWin11 default,LANofHost
```
*(Make sure to remove the network config from the default profile or override it).*

## 3. Firewall & Troubleshooting

### VM has no internet in Bridged Mode?
Linux host firewalls often block bridged traffic. Disable netfilter on the bridge:

```bash
# Temporary
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0
sudo sysctl -w net.bridge.bridge-nf-call-arptables=0

# Permanent
echo "net.bridge.bridge-nf-call-iptables=0" | sudo tee /etc/sysctl.d/99-bridge-disable-firewall.conf
```

### USB Adapters
Some USB network adapters drop packets with "foreign" MAC addresses (PROMISC mode issues).
Force promiscuous mode:
```bash
sudo ip link set dev eth0 promisc on
```
Permanent NetworkManager setting:
```bash
sudo nmcli connection modify br0-slave-eth0 802-3-ethernet.auto-negotiate yes
```
