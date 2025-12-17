#!/bin/bash
# Find seedbox IP using nmap + .storage size check

NETWORK="${1:-192.168.3.0/24}"
HA_PORT="8123"
SSH_USERS="ubuntu root"  # Try both

# Check required dependencies
echo "Checking dependencies..."
MISSING_DEPS=()
for CMD in nmap avahi-resolve ssh rsync; do
    if ! command -v $CMD &> /dev/null; then
        MISSING_DEPS+=("$CMD")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "❌ ERROR: Missing required commands: ${MISSING_DEPS[*]}"
    echo "Install with: sudo apt install nmap avahi-utils openssh-client rsync"
    exit 1
fi
echo "✅ All dependencies found"
echo ""

echo "Scanning $NETWORK for HA instances..."
IPS=$(nmap -p $HA_PORT --open $NETWORK -oG - 2>/dev/null | grep "$HA_PORT/open" | awk '{print $2}')

if [ -z "$IPS" ]; then
    echo "❌ ERROR: No HA instances found on $NETWORK"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check if HA is running: curl http://<IP>:$HA_PORT"
    echo "  2. Check network range is correct: $NETWORK"
    echo "  3. Check firewall allows port scanning"
    echo "  4. Try manual scan: nmap -p $HA_PORT --open $NETWORK"
    exit 1
fi

echo "Found HA instance(s):"
echo "$IPS"
echo ""

LARGEST_IP=""
LARGEST_SIZE=0

for IP in $IPS; do
    echo "Checking $IP..."
    
    FOUND_USER=""
    # Try to find working SSH user
    for USER in $SSH_USERS; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o BatchMode=yes $USER@$IP "exit" 2>/dev/null; then
            FOUND_USER=$USER
            break
        fi
    done
    
    if [ -z "$FOUND_USER" ]; then
        echo "  ❌ No SSH access (tried: $SSH_USERS)"
        continue
    fi
    
    echo "  ✅ SSH: $FOUND_USER@$IP"
    
    # Try multiple possible .storage locations
    STORAGE_PATH=""
    for PATH_CHECK in "/config/.storage" "/home/$FOUND_USER/homelab/target/homeassistant-ansible/config/.storage" "/home/$FOUND_USER/homelab/target/homeassistant/config/.storage"; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no $FOUND_USER@$IP "test -d $PATH_CHECK" 2>/dev/null; then
            STORAGE_PATH=$PATH_CHECK
            echo "  ✅ Found .storage at: $STORAGE_PATH"
            break
        fi
    done
    
    if [ -z "$STORAGE_PATH" ]; then
        echo "  ❌ No .storage folder found"
        continue
    fi
    
    # Get size in bytes
    SIZE=$(ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no $FOUND_USER@$IP "du -sb $STORAGE_PATH 2>/dev/null | cut -f1" 2>/dev/null)
    
    if [ -z "$SIZE" ]; then
        echo "  ⚠️  Could not read .storage size"
        continue
    fi
    
    SIZE_MB=$((SIZE / 1024 / 1024))
    echo "  ✅ .storage size: ${SIZE_MB}MB"
    
    if [ "$SIZE" -gt "$LARGEST_SIZE" ]; then
        LARGEST_SIZE=$SIZE
        LARGEST_IP=$IP
    fi
done

echo ""
if [ -n "$LARGEST_IP" ]; then
    echo "✅ Seedbox IP: $LARGEST_IP (${LARGEST_SIZE}/$((LARGEST_SIZE / 1024 / 1024))MB)"
    echo "$LARGEST_IP"
else
    echo "❌ ERROR: No valid seedbox found"
    echo ""
    echo "Found HA instances but none had accessible .storage:"
    for IP in $IPS; do
        echo "  - $IP (check SSH access and .storage location)"
    done
    exit 1
fi
