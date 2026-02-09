#!/bin/bash

# Configuration
VMS=("gipDLVmWin11" "gipDLVmUb22A")
PROFILE="LANofHost"
BRIDGE_NAME="br0"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting Network Switch to Host LAN...${NC}"

# 1. Detect Active Interface and Gateway
DEFAULT_ROUTE=$(ip route show default | head -n1)
INTERFACE=$(echo $DEFAULT_ROUTE | awk '{print $5}')

if [ -z "$INTERFACE" ]; then
    echo -e "${RED}Error: No active network interface found!${NC}"
    exit 1
fi

echo -e "Detected active interface: ${GREEN}$INTERFACE${NC}"

# 2. Detect Interface Type
TYPE=$(nmcli -t -f DEVICE,TYPE device | grep "^${INTERFACE}:" | cut -d: -f2)
echo -e "Interface type: ${GREEN}$TYPE${NC}"

# 3. Configure Network based on Type
if [ "$TYPE" == "ethernet" ]; then
    echo -e "${YELLOW}Ethernet detected. Configuring Bridge ($BRIDGE_NAME)...${NC}"

    # Check if bridge already exists
    if nmcli connection show "$BRIDGE_NAME" >/dev/null 2>&1; then
        echo "Bridge $BRIDGE_NAME already exists."
    else
        # Identify current connection on the interface
        CURRENT_CON=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":${INTERFACE}$" | cut -d: -f1)
        
        echo "Creating bridge $BRIDGE_NAME..."
        nmcli connection add type bridge ifname "$BRIDGE_NAME" con-name "$BRIDGE_NAME" bridge.stp no
        
        echo "Adding slave interface $INTERFACE..."
        nmcli connection add type bridge-slave ifname "$INTERFACE" master "$BRIDGE_NAME" con-name "${BRIDGE_NAME}-slave-${INTERFACE}"
        
        # Adjust NetworkManager setting for PROMISC issues (as per guide)
        nmcli connection modify "${BRIDGE_NAME}-slave-${INTERFACE}" 802-3-ethernet.auto-negotiate yes

        # Disable firewall on bridge (sysctl)
        echo "Disabling netfilter on bridge..."
        sudo sysctl -w net.bridge.bridge-nf-call-iptables=0
        sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0
        sudo sysctl -w net.bridge.bridge-nf-call-arptables=0
        
        # Switch connections
        echo "Activating bridge..."
        if [ ! -z "$CURRENT_CON" ]; then
            nmcli connection down "$CURRENT_CON"
        fi
        nmcli connection up "$BRIDGE_NAME"
        nmcli connection up "${BRIDGE_NAME}-slave-${INTERFACE}"
    fi

    # Update Incus Profile for Bridged Mode
    echo "Updating Incus profile $PROFILE for Bridged mode..."
    incus profile device set "$PROFILE" eth0 parent="$BRIDGE_NAME"
    incus profile device set "$PROFILE" eth0 nictype=bridged

elif [ "$TYPE" == "wifi" ]; then
    echo -e "${YELLOW}Wi-Fi detected. Standard bridging not supported on client Wi-Fi.${NC}"
    echo -e "${YELLOW}Switching to 'ipvlan' mode for Incus.${NC}"
    
    # Update Incus Profile for ipvlan Mode
    # Note: ipvlan allows VM to talk to outside, but has some limitations compared to true bridge.
    # For VMs, nictype=ipvlan is supported in recent Incus versions.
    
    echo "Updating Incus profile $PROFILE for macvlan/ipvlan mode (ipvlan recommended for wifi)..."
    incus profile device set "$PROFILE" eth0 parent="$INTERFACE"
    incus profile device set "$PROFILE" eth0 nictype=ipvlan
    
    # Note: If ipvlan fails for VMs, 'routed' might be needed, but 'ipvlan' is the closest single-switch attempt.

else
    echo -e "${RED}Unsupported interface type: $TYPE${NC}"
    exit 1
fi

# 4. Assign Profile to VMs
for VM in "${VMS[@]}"; do
    echo -e "Assigning $PROFILE to ${GREEN}$VM${NC}..."
    # Check if profile is already assigned
    CURRENT_PROFILES=$(incus config show "$VM" | grep "profiles:" -A10 | grep -v "profiles:" | awk '{print $2}')
    
    if [[ $CURRENT_PROFILES != *"$PROFILE"* ]]; then
        # Append LANofHost to existing profiles (usually default)
        # We assume 'default' is there. We set it to "default,LANofHost"
        incus profile assign "$VM" default,"$PROFILE"
        echo "Profile assigned."
        
        # Restart VM to apply network changes if running
        STATE=$(incus info "$VM" | grep "Status:" | awk '{print $2}')
        if [ "$STATE" == "Running" ]; then
             echo "Restarting $VM to apply changes..."
             incus restart "$VM"
        fi
    else
        echo "$VM already has $PROFILE."
    fi
done

echo -e "${GREEN}Switch complete. VMs are now connected to the Host Network.${NC}"
