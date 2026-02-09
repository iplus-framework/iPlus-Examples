#!/bin/bash

# Configuration
VMS=("gipDLVmWin11" "gipDLVmUb22A")
PROFILE="LANofHost"
# Also clean up "DirectNet" just in case mixed usage occurred
PROFILE2="DirectNet"
BRIDGE_NAME="br0"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Reverting Network to Incus Default NAT (Robust Clean)...${NC}"

# 1. Reset VM Profiles
for VM in "${VMS[@]}"; do
    echo -e "Resetting $VM to default profile..."
    incus profile assign "$VM" default
    
    # Restart VM if running
    STATE=$(incus info "$VM" | grep "Status:" | awk '{print $2}')
    if [ "$STATE" == "Running" ]; then
         echo "Restarting $VM..."
         incus restart "$VM"
    fi
done

# 2. Complete Cleanup of Host Bridge and Slaves
if nmcli connection show "$BRIDGE_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}Deleting bridge connection '$BRIDGE_NAME'...${NC}"
    nmcli connection down "$BRIDGE_NAME" 2>/dev/null
    nmcli connection delete "$BRIDGE_NAME" 2>/dev/null
fi

# Aggressively delete all 'bridge-slave' connections attached to this bridge
# OR named with the standard pattern we used (br0-slave-*)
echo -e "${YELLOW}Scanning for leftover slave connections...${NC}"

# Find by Name Pattern
SLAVES_BY_NAME=$(nmcli -t -f NAME connection show | grep "^${BRIDGE_NAME}-slave-")

# Simple iteration
for SLAVE in $SLAVES_BY_NAME; do
    if [ ! -z "$SLAVE" ]; then
        echo -e "Deleting slave connection: ${RED}$SLAVE${NC}"
        
        # Try to deduce the physical interface from the slave name or settings
        # Pattern: br0-slave-INTERFACE
        DETECTED_IFACE=$(echo "$SLAVE" | sed "s/^${BRIDGE_NAME}-slave-//")
        
        if [ ! -z "$DETECTED_IFACE" ] && [ "$DETECTED_IFACE" != "--" ]; then
            LAST_KNOWN_IFACE="$DETECTED_IFACE"
        fi

        nmcli connection delete "$SLAVE"
    fi
done

# 3. Restore management of Physical Interface
# If we didn't detect interface from slave process, try to guess the most likely Ethernet candidate
if [ -z "$LAST_KNOWN_IFACE" ]; then
    # Look for the first unmanaged or disconnected ethernet device
    LAST_KNOWN_IFACE=$(nmcli -t -f DEVICE,TYPE,STATE device | grep ":ethernet" | grep -v ":connected" | head -n1 | cut -d: -f1)
fi

if [ ! -z "$LAST_KNOWN_IFACE" ]; then
    echo -e "Checking connectivity for interface: ${GREEN}$LAST_KNOWN_IFACE${NC}"
    
    # Disable Promiscuous Mode (just in case)
    if ip link show "$LAST_KNOWN_IFACE" 2>/dev/null | grep -q "PROMISC"; then
        echo "Disabling promiscuous mode..."
        sudo ip link set dev "$LAST_KNOWN_IFACE" promisc off
    fi

    # Check if a valid profile exists for this device
    # We look broadly for ANY connection of type ethernet linked to this interface, OR any generic ethernet connection if unique
    EXISTING_CON=$(nmcli -t -f NAME,DEVICE connection show | grep ":${LAST_KNOWN_IFACE}" | head -n1 | cut -d: -f1)
    
    # If no explicit device match, look for "Kabelgebundene Verbindung 1" that is unassigned (--)
    if [ -z "$EXISTING_CON" ]; then
         EXISTING_CON=$(nmcli -t -f NAME,DEVICE,TYPE connection show | grep ":--:ethernet" | grep "Kabelgebundene" | head -n1 | cut -d: -f1)
         
         if [ ! -z "$EXISTING_CON" ]; then
             echo -e "Found unassigned connection '${EXISTING_CON}', rebinding to ${LAST_KNOWN_IFACE}..."
             nmcli connection modify "$EXISTING_CON" connection.interface-name "$LAST_KNOWN_IFACE"
         fi
    fi

    if [ -z "$EXISTING_CON" ]; then
        echo -e "${YELLOW}No existing connection profile found for $LAST_KNOWN_IFACE.${NC}"
        echo -e "Creating new standard 'Kabelgebundene Verbindung'..."
        nmcli connection add type ethernet ifname "$LAST_KNOWN_IFACE" con-name "Kabelgebundene Verbindung 1"
        EXISTING_CON="Kabelgebundene Verbindung 1"
    else
        echo -e "Found existing connection: $EXISTING_CON"
    fi
    
    # Check link state before forcing up (Avoid errors if on Wi-Fi/Cable Unplugged)
    if ip link show "$LAST_KNOWN_IFACE" 2>/dev/null | grep -q "NO-CARRIER"; then
         echo -e "${YELLOW}Interface $LAST_KNOWN_IFACE is unplugged (No Carrier). Config restored, but skipping activation.${NC}"
    else
         echo -e "Activating ${GREEN}$EXISTING_CON${NC}..."
         nmcli connection up "$EXISTING_CON" 2>/dev/null || nmcli device connect "$LAST_KNOWN_IFACE"
    fi
else
    echo "No relevant ethernet interface found to restore."
fi

echo -e "${GREEN}Revert complete.${NC}"
