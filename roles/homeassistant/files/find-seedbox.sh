#!/bin/bash
# Find seedbox IP using nmap + .storage size check (through positional arguments)
NETWORK="$1"
HA_PORT="$2"
shift 2
EXCLUDE_IPS="$*"  # Optional: IPs to exclude (space-separated, usually all target IPs)
SSH_USERS="ubuntu root"  # Try both

if [ -z "$NETWORK" ] || [ -z "$HA_PORT" ]; then
    echo "❌ ERROR: Both NETWORK and HA_PORT are required!"
    echo "Usage: $0 <NETWORK> <HA_PORT> [EXCLUDE_IP...]"
    echo "Example: $0 192.168.3.0/24 8123 192.168.3.26 192.168.3.33"
    exit 1
fi

# Convert exclude IPs to array for easy checking
declare -A EXCLUDE_MAP
for ip in $EXCLUDE_IPS; do
    EXCLUDE_MAP[$ip]=1
done

# Auto-detect SSH key (runner has deployed key, Linux box uses agent forwarding)
if [ -f ~/.ssh/id_ed25519_seedbox_priv ]; then
    SSH_KEY_ARG="-i ~/.ssh/id_ed25519_seedbox_priv"
    echo "Using deployed SSH key"
else
    SSH_KEY_ARG=""
    echo "Using SSH agent forwarding"
fi
echo ""

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
    # Skip if this is one of the excluded IPs (target itself)
    if [ -n "${EXCLUDE_MAP[$IP]}" ]; then
        echo "  ⏭️  Skipping $IP (target itself)"
        continue
    fi

    echo "Checking $IP..."

    FOUND_USER=""
    # Try to find working SSH user
    for USER in $SSH_USERS; do
        if ssh $SSH_KEY_ARG -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o BatchMode=yes $USER@$IP "exit" 2>/dev/null; then
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
        if ssh $SSH_KEY_ARG -o ConnectTimeout=2 -o StrictHostKeyChecking=no $FOUND_USER@$IP "test -d $PATH_CHECK" 2>/dev/null; then
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
    SIZE=$(ssh $SSH_KEY_ARG -o ConnectTimeout=2 -o StrictHostKeyChecking=no $FOUND_USER@$IP "du -sb $STORAGE_PATH 2>/dev/null | cut -f1" 2>/dev/null)
    
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
        if [ -n "${EXCLUDE_MAP[$IP]}" ]; then
            continue
        fi
        echo "  - $IP (check SSH access and .storage location)"
    done
    exit 1
fi
