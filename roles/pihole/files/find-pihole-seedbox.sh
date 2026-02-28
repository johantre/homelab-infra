#!/bin/bash
# Find PiHole seedbox IP using nmap + SSH verification
# Usage: find-pihole-seedbox.sh <NETWORK> <PIHOLE_HTTP_PORT> [EXCLUDE_IP...]
NETWORK="$1"
PIHOLE_PORT="$2"
shift 2
EXCLUDE_IPS="$*"  # Optional: IPs to exclude (space-separated, usually all target IPs)
SSH_USERS="ubuntu root"  # Try both

if [ -z "$NETWORK" ] || [ -z "$PIHOLE_PORT" ]; then
    echo "❌ ERROR: Both NETWORK and PIHOLE_PORT are required!"
    echo "Usage: $0 <NETWORK> <PIHOLE_HTTP_PORT> [EXCLUDE_IP...]"
    echo "Example: $0 192.168.3.0/24 80 192.168.3.26 192.168.3.33"
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
for CMD in nmap ssh; do
    if ! command -v $CMD &> /dev/null; then
        MISSING_DEPS+=("$CMD")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "❌ ERROR: Missing required commands: ${MISSING_DEPS[*]}"
    echo "Install with: sudo apt install nmap openssh-client"
    exit 1
fi
echo "✅ All dependencies found"
echo ""

echo "🔎 Scanning $NETWORK for PiHole instances (port $PIHOLE_PORT)..."
IPS=$(nmap -p $PIHOLE_PORT --open $NETWORK -oG - 2>/dev/null | grep "$PIHOLE_PORT/open" | awk '{print $2}')

if [ -z "$IPS" ]; then
    echo "❌ ERROR: No hosts with port $PIHOLE_PORT found on $NETWORK"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check if PiHole is running: curl http://<IP>:$PIHOLE_PORT/admin/"
    echo "  2. Check network range is correct: $NETWORK"
    echo "  3. Try manual scan: nmap -p $PIHOLE_PORT --open $NETWORK"
    exit 1
fi

echo "Found host(s) with port $PIHOLE_PORT open:"
echo "$IPS"
echo ""

FOUND_PIHOLE_IP=""
FOUND_PIHOLE_SIZE=0

for IP in $IPS; do
    # Skip if this is one of the excluded IPs (target itself)
    if [ -n "${EXCLUDE_MAP[$IP]}" ]; then
        echo "⏭️  Skipping $IP (target itself)"
        continue
    fi

    echo "🔍 Checking $IP for PiHole..."

    FOUND_USER=""
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

    # Verify PiHole is actually installed (native or Docker)
    PIHOLE_DETECTED=$(ssh $SSH_KEY_ARG -o ConnectTimeout=3 -o StrictHostKeyChecking=no $FOUND_USER@$IP "
        if docker ps 2>/dev/null | grep -q pihole; then
            echo 'docker'
        elif [ -f /etc/pihole/pihole.toml ]; then
            echo 'native'
        else
            echo 'none'
        fi
    " 2>/dev/null)

    if [ "$PIHOLE_DETECTED" = "none" ] || [ -z "$PIHOLE_DETECTED" ]; then
        echo "  ❌ PiHole not detected on $IP (port $PIHOLE_PORT open but no PiHole found)"
        continue
    fi

    echo "  ✅ PiHole detected ($PIHOLE_DETECTED)"

    # Use gravity.db size as tie-breaker (largest = most data = production)
    GRAVITY_SIZE=$(ssh $SSH_KEY_ARG -o ConnectTimeout=3 -o StrictHostKeyChecking=no $FOUND_USER@$IP "
        if [ '$PIHOLE_DETECTED' = 'docker' ]; then
            CONTAINER=\$(docker ps --filter 'ancestor=pihole/pihole' --format '{{.Names}}' | head -1)
            [ -z \"\$CONTAINER\" ] && CONTAINER=\$(docker ps | grep pihole | awk '{print \$NF}' | head -1)
            VOL=\$(docker inspect \"\$CONTAINER\" --format '{{range .Mounts}}{{.Source}} {{.Destination}}{{println}}{{end}}' 2>/dev/null | grep '/etc/pihole' | awk '{print \$1}')
            [ -n \"\$VOL\" ] && stat -c%s \"\$VOL/gravity.db\" 2>/dev/null || echo 0
        else
            stat -c%s /etc/pihole/gravity.db 2>/dev/null || echo 0
        fi
    " 2>/dev/null | tr -d '[:space:]')

    GRAVITY_SIZE=${GRAVITY_SIZE:-0}
    GRAVITY_MB=$(( GRAVITY_SIZE / 1024 / 1024 ))
    echo "  ✅ gravity.db size: ${GRAVITY_MB}MB"

    if [ "$GRAVITY_SIZE" -ge "$FOUND_PIHOLE_SIZE" ]; then
        FOUND_PIHOLE_SIZE=$GRAVITY_SIZE
        FOUND_PIHOLE_IP=$IP
    fi
done

echo ""
if [ -n "$FOUND_PIHOLE_IP" ]; then
    echo "✅ PiHole seedbox found: $FOUND_PIHOLE_IP (gravity.db: $((FOUND_PIHOLE_SIZE / 1024 / 1024))MB)"
    echo "$FOUND_PIHOLE_IP"
else
    echo "❌ ERROR: No valid PiHole seedbox found on $NETWORK"
    exit 1
fi
