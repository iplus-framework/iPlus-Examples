#!/bin/bash

# Configuration
VMS=("gipDLVmWin11" "gipDLVmUb22A")
PROFILE="DirectNet"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting Network Switch to Macvlan...${NC}"

# Check for existing bridge (conflict check)
if nmcli connection show "br0" >/dev/null 2>&1; then
    echo -e "${RED}Error: Host bridge 'br0' detected.${NC}"
    echo "Please run 'switch-to-incus-nat-simple.sh' to revert the bridge configuration first."
    exit 1
fi

# 1. Detect Active Interface
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

# 3. Configure Profile
# We use standard macvlan (macvtap) for Ethernet. 
# This is stable for Windows VirtIO drivers.
if [ "$TYPE" == "ethernet" ]; then
    echo -e "${YELLOW}Ethernet detected. Configuring Macvlan...${NC}"
    echo -e "${YELLOW}NOTE: If your USB Hub blocks multiple MACs, the VM may not get an IP.${NC}"
    
    # Try to verify promiscuous mode is on (helper, but not strictly modifying hardware if failed)
    sudo ip link set dev "$INTERFACE" promisc on 2>/dev/null
    
    # Update Incus Profile for Macvlan
    incus profile device set "$PROFILE" eth0 parent="$INTERFACE"
    incus profile device set "$PROFILE" eth0 nictype=macvlan

elif [ "$TYPE" == "wifi" ]; then
    echo -e "${YELLOW}Wi-Fi detected. Configuring Ipvlan...${NC}"
    echo -e "Note: Macvlan does not work on Wi-Fi client connections."
    
    # Ensure ipvtap is loaded for Wifi support (only if needed)
    if ! lsmod | grep -q "ipvtap"; then
         sudo modprobe ipvtap
    fi

    # Update Incus Profile for Ipvlan
    incus profile device set "$PROFILE" eth0 parent="$INTERFACE"
    incus profile device set "$PROFILE" eth0 nictype=ipvlan

else
    echo -e "${RED}Unsupported interface type: $TYPE${NC}"
    exit 1
fi

# 4. Assign Profile to VMs
for VM in "${VMS[@]}"; do
    echo -e "Assigning $PROFILE to ${GREEN}$VM${NC}..."
    
    # Remove LANofHost if present to avoid conflicts (clean slate)
    # Assign default + DirectNet
    incus profile assign "$VM" default,"$PROFILE"
    
    # Check if currently running and restart
    STATE=$(incus info "$VM" | grep "Status:" | awk '{print $2}')
    if [ "$STATE" == "Running" ]; then
         echo "Restarting $VM to apply changes..."
         incus restart "$VM"
    fi
done

echo -e "${GREEN}Switch complete. VMs are using DirectNet profile on $INTERFACE.${NC}"
